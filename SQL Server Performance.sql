USE [Performance] 
GO

CREATE VIEW PerfMon AS
SELECT CONVERT(DATETIME, CAST(CounterDateTime AS VARCHAR(19))) AS CounterDateTime,
MachineName, ObjectName, CounterName, InstanceName, CounterValue
FROM dbo.CounterData AS D JOIN dbo.CounterDetails AS C ON D.CounterID = C.CounterID 
ORDER BY CounterDateTime;
GO

SELECT *
FROM [Performance]..PerfMon;
GO

SELECT
  events.event.value('@timestamp', 'datetime') AS EventTime,
  events.event.query('.').value('(/event/@name)[1]', 'varchar(255)') as EventName
FROM (
  SELECT convert(xml, event_data) AS event_data
  FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
) AS system_health
CROSS APPLY system_health.event_data.nodes('/event') AS events(event);
GO

IF EXISTS(SELECT * FROM sys.server_event_sessions WHERE name='TrackResourceWaits')
DROP EVENT SESSION TrackResourceWaits ON SERVER
GO

CREATE EVENT SESSION [TrackResourceWaits] ON SERVER 
ADD EVENT  sqlos.wait_info
( 
    ACTION(sqlserver.database_id,sqlserver.session_id,sqlserver.sql_text,sqlserver.plan_handle)
    WHERE
        (opcode = 1 
            AND duration > 100 
            AND ((wait_type > 0 AND wait_type < 22) -- LCK_ waits
                    OR (wait_type > 31 AND wait_type < 38) -- LATCH_ waits
                    OR (wait_type > 47 AND wait_type < 54) -- PAGELATCH_ waits
                    OR (wait_type > 63 AND wait_type < 70) -- PAGEIOLATCH_ waits
                    OR (wait_type > 96 AND wait_type < 100) -- IO (Disk/Network) waits
                    OR (wait_type = 107) -- RESOURCE_SEMAPHORE waits
                    OR (wait_type = 113) -- SOS_WORKER waits
                    OR (wait_type = 120) -- SOS_SCHEDULER_YIELD waits
                    OR (wait_type = 178) -- WRITELOG waits
                    OR (wait_type > 174 AND wait_type < 177) -- FCB_REPLICA_ waits
                    OR (wait_type = 186) -- CMEMTHREAD waits
                    OR (wait_type = 187) -- CXPACKET waits
                    OR (wait_type = 207) -- TRACEWRITE waits
                    OR (wait_type = 269) -- RESOURCE_SEMAPHORE_MUTEX waits
                    OR (wait_type = 283) -- RESOURCE_SEMAPHORE_QUERY_COMPILE waits
                    OR (wait_type = 284) -- RESOURCE_SEMAPHORE_SMALL_QUERY waits
                )
        )
)
ADD TARGET package0.ring_buffer(SET max_events_limit=(0 /*unlimited*/),max_memory=(1048576 /*1 GB*/))
WITH (STARTUP_STATE=OFF,
	  EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,
      MAX_DISPATCH_LATENCY=5 SECONDS);
GO

ALTER EVENT SESSION [TrackResourceWaits] ON SERVER
STATE=START
GO

SELECT 
    DATEADD(hh, 
        DATEDIFF(hh, GETUTCDATE(), CURRENT_TIMESTAMP), 
        event_data.value('(event/@timestamp)[1]', 'datetime2')) AS [timestamp],
    DB_NAME(COALESCE(event_data.value('(event/data[@name="database_id"]/value)[1]', 'int'), 
        event_data.value('(event/action[@name="database_id"]/value)[1]', 'int'))) AS [database],
    event_data.value('(event/action[@name="session_id"]/value)[1]', 'int') AS [session_id],
    event_data.value('(event/data[@name="wait_type"]/text)[1]', 'nvarchar(4000)') AS [wait_type],
    event_data.value('(event/data[@name="duration"]/value)[1]', 'bigint') AS [duration],
    event_data.value('(event/data[@name="signal_duration"]/value)[1]', 'bigint') AS [signal_duration],
    event_data.value('(event/action[@name="plan_handle"]/value)[1]', 'nvarchar(4000)') AS [plan_handle],
    event_data.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(4000)') AS [sql_text]
FROM 
(   SELECT XEvent.query('.') AS event_data 
    FROM 
    (SELECT CAST(target_data AS XML) AS TargetData 
     FROM sys.dm_xe_session_targets st 
     JOIN sys.dm_xe_sessions s 
            ON s.address = st.event_session_address 
     WHERE name = 'TrackResourceWaits' 
          AND target_name = 'ring_buffer'
    ) AS Data  
    CROSS APPLY TargetData.nodes ('RingBufferTarget/event') AS XEventData (XEvent)   
) AS tab (event_data);
GO

IF EXISTS(SELECT * FROM sys.server_event_sessions WHERE name='LongRunningQueries')
DROP EVENT SESSION [LongRunningQueries] ON SERVER
GO

CREATE EVENT SESSION [LongRunningQueries] ON SERVER
ADD EVENT sqlserver.sp_statement_completed
(
	ACTION
	(
	package0.collect_system_time
	,sqlserver.client_app_name
	,sqlserver.client_hostname
	,sqlserver.username
	,sqlserver.database_name
	)
	WHERE duration > 100000 -- longer than 1 seconds
)
ADD TARGET package0.ring_buffer(SET max_events_limit=(0 /*unlimited*/),max_memory=(1048576 /*1 GB*/))
WITH (STARTUP_STATE=OFF,
	  MAX_DISPATCH_LATENCY = 5 SECONDS, 
	  EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS);
GO

ALTER EVENT SESSION [LongRunningQueries] ON SERVER
STATE=START
GO

SELECT DATEADD(hh, DATEDIFF(hh, GETUTCDATE(), CURRENT_TIMESTAMP), 
        event_data.value('(event/@timestamp)[1]', 'datetime2')) AS [timestamp],
event_data.value('(event/data[@name="statement"]/value)[1]', 'varchar(max)') AS statement,
event_data.value('(event/data[@name="duration"]/value)[1]', 'bigint')/1000 AS duration_ms,
event_data.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint')/1000 AS cpu_time_ms,
event_data.value('(event/data[@name="physical_reads"]/value)[1]', 'bigint') AS physical_reads,
event_data.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads,
event_data.value('(event/data[@name="writes"]/value)[1]', 'bigint') AS writes,
event_data.value('(event/action[@name="database_name"]/value)[1]', 'varchar(255)') AS database_name,
event_data.value('(event/action[@name="client_hostname"]/value)[1]', 'varchar(255)') AS client_hostname,
event_data.value('(event/action[@name="username"]/value)[1]', 'varchar(255)') AS username,
event_data.value('(event/action[@name="client_app_name"]/value)[1]', 'varchar(255)') AS [app_name]
FROM 
(   SELECT XEvent.query('.') AS event_data 
    FROM 
    (SELECT CAST(target_data AS XML) AS TargetData 
     FROM sys.dm_xe_session_targets st 
     JOIN sys.dm_xe_sessions s 
            ON s.address = st.event_session_address 
     WHERE name = 'LongRunningQueries' 
          AND target_name = 'ring_buffer'
    ) AS Data  
    CROSS APPLY TargetData.nodes ('RingBufferTarget/event') AS XEventData (XEvent)   
) AS tab (event_data);
GO