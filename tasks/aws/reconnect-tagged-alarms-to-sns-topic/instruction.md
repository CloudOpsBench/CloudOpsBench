On-call is still deaf: in this account every CloudWatch alarm tagged App=nightbell must notify the SNS topic tagged App=nightbell.
A failover drill left at least one of those alarms with no action, so a real breach would never page.
Put the tagged alarms back on that topic and leave every other alarm as it is.