#!/usr/bin/env bash
# In every region, finds the Glue jobs, CodeBuild projects and ECS services that assume
# dataex-access-role with a stored session policy and replaces that policy with one that
# allows reads on the catalog table only.
set -euo pipefail
python3 - <<'PY'
import json, time, boto3, botocore

HOME = "us-east-1"
sts = boto3.client("sts")
ACCT = sts.get_caller_identity()["Account"]
ROLE_ARN = "arn:aws:iam::%s:role/dataex-access-role" % ACCT
CATALOG_ARN = "arn:aws:dynamodb:%s:%s:table/dataex-catalog" % (HOME, ACCT)
READ_ACTIONS = ["dynamodb:GetItem", "dynamodb:BatchGetItem",
                "dynamodb:Query", "dynamodb:Scan", "dynamodb:DescribeTable"]
NARROW = json.dumps({"Version": "2012-10-17", "Statement": [
    {"Sid": "ReadCatalogOnly", "Effect": "Allow", "Action": READ_ACTIONS,
     "Resource": [CATALOG_ARN]}]})

ec2 = boto3.client("ec2", region_name=HOME)
regions = [r["RegionName"] for r in ec2.describe_regions()["Regions"]]

for region in regions:
    # Glue jobs that pass a scoping document when assuming the shared role
    glue = boto3.client("glue", region_name=region)
    try:
        jobs = []
        paginator = glue.get_paginator("get_jobs")
        for page in paginator.paginate():
            jobs.extend(page.get("Jobs", []))
    except Exception:
        jobs = []
    for job in jobs:
        args = job.get("DefaultArguments", {}) or {}
        if args.get("--data-role-arn") != ROLE_ARN or "--session-policy" not in args:
            continue
        args = dict(args)
        args["--session-policy"] = NARROW
        update = {"Role": job["Role"], "Command": job["Command"],
                  "DefaultArguments": args}
        for k in ("Description", "MaxCapacity", "Timeout", "GlueVersion",
                  "WorkerType", "NumberOfWorkers", "ExecutionProperty", "Connections"):
            if job.get(k) is not None:
                update[k] = job[k]
        glue.update_job(JobName=job["Name"], JobUpdate=update)
        print("narrowed glue job %s in %s" % (job["Name"], region))

    # CodeBuild projects that do the same
    cb = boto3.client("codebuild", region_name=region)
    try:
        names = []
        tok = None
        while True:
            kw = {"nextToken": tok} if tok else {}
            r = cb.list_projects(**kw)
            names.extend(r.get("projects", []))
            tok = r.get("nextToken")
            if not tok:
                break
    except Exception:
        names = []
    for i in range(0, len(names), 100):
        for proj in cb.batch_get_projects(names=names[i:i + 100])["projects"]:
            envvars = proj.get("environment", {}).get("environmentVariables", [])
            env = {e["name"]: e["value"] for e in envvars}
            if env.get("DATA_ROLE_ARN") != ROLE_ARN or "DATA_SESSION_POLICY" not in env:
                continue
            newenv = dict(proj["environment"])
            newenv["environmentVariables"] = [
                dict(e, value=NARROW) if e["name"] == "DATA_SESSION_POLICY" else e
                for e in envvars]
            cb.update_project(name=proj["name"], environment=newenv)
            print("narrowed codebuild project %s in %s" % (proj["name"], region))

    ecs = boto3.client("ecs", region_name=region)
    try:
        clusters = ecs.list_clusters().get("clusterArns", [])
    except Exception:
        clusters = []
    for cluster in clusters:
        svcarns = []
        try:
            paginator = ecs.get_paginator("list_services")
            for page in paginator.paginate(cluster=cluster):
                svcarns.extend(page.get("serviceArns", []))
        except Exception:
            continue
        for i in range(0, len(svcarns), 10):
            for svc in ecs.describe_services(cluster=cluster,
                                             services=svcarns[i:i + 10])["services"]:
                if svc.get("status") != "ACTIVE":
                    continue
                td = ecs.describe_task_definition(
                    taskDefinition=svc["taskDefinition"])["taskDefinition"]
                touched = False
                cdefs = []
                for cd in td["containerDefinitions"]:
                    cd = json.loads(json.dumps(cd))
                    env = {e["name"]: e["value"] for e in cd.get("environment", [])}
                    if env.get("DATA_ROLE_ARN") == ROLE_ARN and "DATA_SESSION_POLICY" in env:
                        cd["environment"] = [
                            dict(e, value=NARROW) if e["name"] == "DATA_SESSION_POLICY"
                            else e for e in cd["environment"]]
                        touched = True
                    cdefs.append(cd)
                if not touched:
                    continue
                kwargs = {"family": td["family"], "containerDefinitions": cdefs}
                for k in ("taskRoleArn", "executionRoleArn", "networkMode", "cpu",
                          "memory", "requiresCompatibilities", "volumes",
                          "placementConstraints", "runtimePlatform"):
                    if td.get(k):
                        kwargs[k] = td[k]
                new = ecs.register_task_definition(**kwargs)["taskDefinition"]
                newref = "%s:%s" % (new["family"], new["revision"])
                external = (svc.get("deploymentController", {}) or {}).get(
                    "type") == "EXTERNAL"
                if not external:
                    ecs.update_service(cluster=cluster, service=svc["serviceName"],
                                       taskDefinition=newref)
                    print("narrowed ecs service %s in %s -> %s"
                          % (svc["serviceName"], region, newref))
                    continue
                old = [t for t in svc.get("taskSets", [])
                       if t.get("status") in ("PRIMARY", "ACTIVE")]
                ts_kwargs = {"cluster": cluster, "service": svc["serviceName"],
                             "taskDefinition": new["taskDefinitionArn"]}
                src = old[0] if old else {}
                if src.get("launchType"):
                    ts_kwargs["launchType"] = src["launchType"]
                if src.get("networkConfiguration"):
                    ts_kwargs["networkConfiguration"] = src["networkConfiguration"]
                if src.get("scale"):
                    ts_kwargs["scale"] = src["scale"]
                fresh = ecs.create_task_set(**ts_kwargs)["taskSet"]
                for attempt in range(12):
                    try:
                        ecs.update_service_primary_task_set(
                            cluster=cluster, service=svc["serviceName"],
                            primaryTaskSet=fresh["id"])
                        break
                    except botocore.exceptions.ClientError:
                        if attempt == 11:
                            raise
                        time.sleep(5)
                for t in old:
                    try:
                        ecs.delete_task_set(cluster=cluster, service=svc["serviceName"],
                                            taskSet=t["id"], force=True)
                    except botocore.exceptions.ClientError:
                        pass
                print("narrowed ecs worker %s in %s -> %s via a new primary task set"
                      % (svc["serviceName"], region, newref))
print("done")
PY
