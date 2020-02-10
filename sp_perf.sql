/*
 * Script for statspack snapshots analysis
 * Run as statspack repository owner, typically "perfstat" user
 * https://github.com/TomaszKaniaX/dba_toolbox/blob/master/sp_perf.sql
 * Author: Tomasz Kania
 * Ver: 0.01 beta
*/

set linesize 2000 pagesize 0 long 2000000 longchunksize 100000 
set termout off
set trimspool on echo off feedback off 
set verify off
set define '&'

--defines 
col global_name new_val db_n noprint
col instance_name new_val inst_n noprint
select global_name from global_name;
select instance_name from v$instance;

col bsnap new_val bsnap noprint
col esnap new_val esnap noprint

col bdate new_val bdate noprint
col edate new_val edate noprint
def DT_FMT_REP="Mon-DD"
select to_char(trunc(sysdate)-7,'&&DT_FMT_REP') as bdate, to_char(trunc(sysdate),'&&DT_FMT_REP') as edate from dual;


set termout on
prompt ==================================================================
ACCEPT bdate  DEFAULT '&bdate'  PROMPT 'Enter start date [&bdate]: '
ACCEPT edate  DEFAULT '&edate'  PROMPT 'Enter start date [&edate]: '
ACCEPT nTopSqls DEFAULT '5'     PROMPT 'Top SQLs per snapshot [5]: '
prompt ==================================================================
set termout off

select min(snap_id) as bsnap from stats$snapshot where snap_time > to_date('&&bdate','&&DT_FMT_REP');
select max(snap_id) as esnap from stats$snapshot where snap_time < to_date('&&edate','&&DT_FMT_REP')+1;


def DT_FMT_ISO="YYYY-MM-DD HH24:MI"
def REPTITLE="Statspack report for &&db_n"

def MAINREPORTFILE=sp_rep_&&bdate._&&edate._&&inst_n..html
spool &&MAINREPORTFILE

prompt <html>
prompt <!-- Statspack reports/graphs -->
prompt <!-- https://github.com/TomaszKaniaX/dba_toolbox/blob/master/sp_perf.sql -->
prompt <!-- Author: tkania.dba@gmail.com -->
prompt <head>
prompt   <title>&&REPTITLE.</title>

---------------------------------------------------
-- GoogleChart JS
---------------------------------------------------
prompt   <script type="text/javascript" src="https://www.gstatic.com/charts/loader.js"></script>
prompt     <script type="text/javascript">
prompt       google.charts.load('current', {'packages':['table', 'corechart', 'controls']});;
prompt       google.charts.setOnLoadCallback(drawDBLoadChart);;  
prompt       google.charts.setOnLoadCallback(drawOSLoadChart);; 
prompt       google.charts.setOnLoadCallback(drawSGAChart);; 
prompt       google.charts.setOnLoadCallback(drawInstActChart);;
prompt       google.charts.setOnLoadCallback(drawWClassChart);;
prompt       google.charts.setOnLoadCallback(drawWaitEvHistChart);;
prompt       google.charts.setOnLoadCallback(drawWaitClHistChart);;
prompt       google.charts.setOnLoadCallback(drawTopSQLChart);;
prompt 
prompt 
---------------------------------------------------
-- DB Load chart
---------------------------------------------------
prompt     function drawDBLoadChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('string', 'Process type');;
prompt       data.addColumn('number', 'CPU Cores');;
prompt       data.addColumn('number', 'DB CPU (%)');;
prompt       data.addColumn('number', 'DB Time (%)');;
prompt       data.addColumn('number', 'Elapsed (min)');;
prompt       data.addColumn('number', 'DB CPU (min)');;
prompt       data.addColumn('number', 'DB Time (min)');;
prompt 
prompt       data.addRows([
with snap as
(
  select snap_id,dbid,instance_number
    ,snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(snap_time,'YYYY')||','||to_char(to_number(to_char(snap_time,'MM'))-1)||','||to_char(snap_time,'DD,HH24,MI') chart_dt
    ,round(((snap_time-lag(snap_time) over (partition by startup_time order by snap_id)))*24*60*60) ela_sec
    ,startup_time,snapshot_exec_time_s
  from stats$snapshot
  where snap_id between &&bsnap and &&esnap
),
stat as
(
select snap_id,snap_time,chart_dt
  ,rn
  ,stat_name
  ,case when stat_name like 'background%' then 'Background' else 'Foreground' end fg_bg
  ,ela_sec
  ,ost.value as cpu_cores
  ,case
    when lag(stm.value) over (partition by tms.stat_name order by snap_id) >  stm.value then round(stm.value/1000000,2)
    else round((stm.value-lag(stm.value) over (partition by tms.stat_name order by snap_id))/1000000,2)
   end sec  
from stats$sys_time_model stm join stats$time_model_statname tms using(stat_id)
join snap using(snap_id,dbid,instance_number)
join stats$osstat ost using(snap_id,dbid,instance_number)
where stat_name in('DB time','DB CPU','background cpu time','background elapsed time')
  and ost.osstat_id = 16 /* NUM_CPU_CORES */
),
group_stat as
(
select snap_time,chart_dt,ela_sec,cpu_cores,fg_bg,
sum(case when stat_name in('DB CPU','background cpu time') then sec else 0 end) as DB_CPU, 
sum(case when stat_name in('DB time','background elapsed time') then sec else 0 end) as DB_TIME
from stat
where ela_sec is not null 
group by rollup(snap_time,chart_dt,ela_sec,cpu_cores,fg_bg) 
order by snap_time,fg_bg
), chart_data as
(
select
--*
  row_number() over (order by snap_time desc,nvl(fg_bg,'Total') desc) rn 
   ,snap_time
   ,chart_dt
  ,nvl(fg_bg,'Total') fg_bg
  ,cpu_cores   
  ,round(DB_CPU/ela_sec,4) db_cpu_pct
  ,round(DB_TIME/ela_sec,4) db_time_pct
  ,round(ela_sec/60,2) ela_min
  ,round(DB_CPU/60,2) db_cpu_min
  ,round(DB_TIME/60,2) db_time_min  
from 
group_stat where ela_sec is not null and cpu_cores is not null and chart_dt is not null
order by snap_time, nvl(fg_bg,'Total')
)
select 
  '[new Date('||chart_dt||'),'||
  ''''||fg_bg||''','||
  cpu_cores||','||
  '{v:'||round(db_cpu_pct,2)||', f:'''||db_cpu_pct*100||'%''}'||','||
  '{v:'||round(db_time_pct,2)||', f:'''||db_time_pct*100||'%''}'||','||
  ela_min||','||
  db_cpu_min||','||
  db_time_min||','||  
  ']'||case when rn=1 then '' else ',' end
from chart_data
order by snap_time, fg_bg;


prompt       ]);;

prompt		var dashboard = new google.visualization.Dashboard(document.getElementById('div_time_model'));;
prompt
prompt        var wclassCategory = new google.visualization.ControlWrapper({
prompt          controlType: 'CategoryFilter',
prompt          containerId: 'div_time_model_filter',
prompt          options: {
prompt            filterColumnLabel: 'Process type',
prompt			ui: {
prompt				allowMultiple: false,
prompt				allowNone: false
prompt			}
prompt          },
prompt			state: {selectedValues: ['Foreground']}
prompt        });;
prompt
prompt       var chart = new google.visualization.ChartWrapper({
prompt          chartType: 'LineChart',
prompt          containerId: 'div_time_model_chart',
prompt          options: {
prompt            	title: 'DB TIME and DB CPU (per snapshot)',
prompt            	backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt            	explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt            	titleTextStyle: {fontSize: 16, bold: true},
prompt            	focusTarget: 'category',
prompt            	legend: {position: 'right', textStyle: {fontSize: 12}},
prompt            	tooltip: {textStyle: {fontSize: 11}},
prompt            	hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt            	vAxis: {title: 'Percent of elapsed time', textStyle: {fontSize: 10}, format: 'percent'}
prompt				},
prompt		  view: {columns: [0,2,3,4]}  
prompt        });;	
prompt
prompt		var table = new google.visualization.ChartWrapper({
prompt          chartType: 'Table',
prompt          containerId: 'div_time_model_tab',
prompt          options: {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}},
prompt		  view: {columns: [0,2,5,6,7,3,4]}  
prompt        });;	
prompt
prompt        dashboard.bind([wclassCategory], [chart, table]);;
prompt        dashboard.draw(data);;	
prompt 
prompt 	}

---------------------------------------------------
-- DB Load chart end
---------------------------------------------------


---------------------------------------------------
-- OS Load chart
---------------------------------------------------
prompt     function drawOSLoadChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('number', 'Total CPU (%)');;
prompt       data.addColumn('number', 'User CPU (%)');;
prompt       data.addColumn('number', 'Kernel CPU (%)');;
prompt       data.addColumn('number', 'IO wait (%)');;
prompt       data.addColumn('number', 'Idle (%)');;
prompt       data.addColumn('number', 'Runqueue');;
prompt 
prompt       data.addRows([
with snap as
(
  select snap_id,dbid,instance_number
    ,snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(snap_time,'YYYY')||','||to_char(to_number(to_char(snap_time,'MM'))-1)||','||to_char(snap_time,'DD,HH24,MI,SS') chart_dt
    ,round(((snap_time-lag(snap_time) over (partition by startup_time order by snap_id)))*24*60*60) ela_sec
    ,startup_time,snapshot_exec_time_s
  from stats$snapshot
  where snap_id between &&bsnap and &&esnap
  and dbid = (select dbid from v$database)
  and instance_number = (select instance_number from v$instance)
),stat as
(
select 
snap_id,dbid,instance_number,stat_name,
case 
  when lag(o.value) over (partition by osstat_id order by snap_id) > o.value then o.value
  else o.value-lag(o.value) over (partition by osstat_id order by snap_id)
end val
from
stats$osstat o join snap using(snap_id, dbid, instance_number)
join stats$osstatname osn using(osstat_id)
where osn.stat_name in('IDLE_TIME','BUSY_TIME','USER_TIME','SYS_TIME','IOWAIT_TIME','LOAD','OS_CPU_WAIT_TIME')
),chart_data as
(
select 
snap_id,dbid,instance_number,
round(busy/(busy+idle+iowait),4) cpu_pct,
round(usrtime /(busy+idle+iowait),4) usr_cpu_pct,
round(systime /(busy+idle+iowait),4) sys_cpu_pct,
round(iowait /(busy+idle+iowait),4) iowait_pct,
round(idle /(busy+idle+iowait),4) idle_pct,
round(runq,2) as runqueue,
trim(to_char(round(busy/(busy+idle+iowait),4)*100,'90.00'))||'%'cpu_pct_f,
trim(to_char(round(usrtime /(busy+idle+iowait),4)*100,'90.00'))||'%' usr_cpu_pct_f,
trim(to_char(round(systime /(busy+idle+iowait),4)*100,'90.00'))||'%' sys_cpu_pct_f,
trim(to_char(round(idle /(busy+idle+iowait),4)*100,'90.00'))||'%' idle_pct_f,
trim(to_char(round(iowait /(busy+idle+iowait),4)*100,'90.00'))||'%' iowait_pct_f
from stat
pivot
  (
    sum(val) for stat_name in(
      'IDLE_TIME' as idle,
      'BUSY_TIME' as busy,
      'USER_TIME' as usrtime,
      'SYS_TIME' as systime,
      'IOWAIT_TIME' as iowait,
      'OS_CPU_WAIT_TIME' as cpuwait,
      'LOAD' as runq
    )
  )
where idle is not null
)
select 
 '[new Date('||chart_dt||'),'||
 '{v:'||cpu_pct||', f:'''||cpu_pct_f||'''}'||','||
 '{v:'||usr_cpu_pct||', f:'''||usr_cpu_pct_f||'''}'||','||
 '{v:'||sys_cpu_pct||', f:'''||sys_cpu_pct_f||'''}'||','||
 '{v:'||iowait_pct||', f:'''||iowait_pct_f||'''}'||','||
 '{v:'||idle_pct||', f:'''||idle_pct_f||'''}'||','||
  runqueue||
  ']'||case when rn=1 then '' else ',' end
from
chart_data join snap using(snap_id, dbid, instance_number)
order by snap_id;



prompt       ]);;
prompt 
prompt       var options = {
prompt            isStacked: true,
prompt            title: 'OS load',
prompt            backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt            explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt            titleTextStyle: {fontSize: 16, bold: true},
prompt            focusTarget: 'category',
prompt            legend: {position: 'right', textStyle: {fontSize: 12}},
prompt            tooltip: {textStyle: {fontSize: 11}},
prompt            hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt            vAxis: {textStyle: {fontSize: 10}, format: 'percent'}
prompt       };;
prompt 
prompt		 var chartView = new google.visualization.DataView(data);;
prompt		 chartView.setColumns([0,2,3,4]);;
prompt       var chart = new google.visualization.AreaChart(document.getElementById('div_os_load_chart'));;
prompt       chart.draw(chartView, options);;
prompt       var table = new google.visualization.Table(document.getElementById('div_os_load_tab'));;
prompt       table.draw(data, {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}});;
prompt	}

---------------------------------------------------
-- OS load chart end
---------------------------------------------------


---------------------------------------------------
-- SGA chart
---------------------------------------------------
prompt     function drawSGAChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('number', 'Fixed SGA');;
prompt       data.addColumn('number', 'Log buffer');;
prompt       data.addColumn('number', 'Java pool');;
prompt       data.addColumn('number', 'Large pool');;
prompt       data.addColumn('number', 'Streams pool');;
prompt       data.addColumn('number', 'Shared IO pool');;
prompt       data.addColumn('number', 'Buffer cache');;
prompt       data.addColumn('number', 'Shared pool');;
prompt 
prompt       data.addRows([

with snap as
(
  select snap_id,dbid,instance_number
    ,snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(snap_time,'YYYY')||','||to_char(to_number(to_char(snap_time,'MM'))-1)||','||to_char(snap_time,'DD,HH24,MI,SS') chart_dt
    ,round(((snap_time-lag(snap_time) over (partition by startup_time order by snap_id)))*24*60*60) ela_sec
    ,startup_time,snapshot_exec_time_s
  from stats$snapshot
  where snap_id between &&bsnap and &&esnap
  and dbid = (select dbid from v$database)
  and instance_number = (select instance_number from v$instance)
),sga_stat as
(
select snap_id,dbid,instance_number,rn,chart_dt,nvl(pool,name) pool,round(bytes/1024/1024) mb 
from stats$sgastat join snap using(snap_id,dbid,instance_number)
)
select 
  '[new Date('||chart_dt||'),'||
  fixed_sga||','||
  log_buffer||','||
  java_pool||','||
  large_pool||','||
  streams_pool||','||
  shared_io_pool||','||
  buffer_cache||','||
  shared_pool||
  ']'||case when rn=1 then '' else ',' end
from sga_stat
pivot
  (
    max(mb)
    for (pool) in
    (
      'fixed_sga' as fixed_sga,
      'log_buffer' as log_buffer,
      'java pool' as java_pool,
      'streams pool' as streams_pool,
      'large pool' as large_pool,
      'shared_io_pool' as shared_io_pool,
      'buffer_cache' as buffer_cache,
      'shared pool' as shared_pool
    )
  )
order by snap_id;


prompt       ]);;
prompt 
prompt       var options = {
prompt            isStacked: true,
prompt            title: 'SGA stat',
prompt            backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt            explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt            titleTextStyle: {fontSize: 16, bold: true},
prompt            focusTarget: 'category',
prompt            legend: {position: 'right', textStyle: {fontSize: 12}},
prompt            tooltip: {textStyle: {fontSize: 11}},
prompt            hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt            vAxis: {title: 'Pool size (MB)', textStyle: {fontSize: 10} }
prompt       };;
prompt 
prompt       var chart = new google.visualization.AreaChart(document.getElementById('div_sga_chart'));;
prompt       chart.draw(data, options);;
prompt       var table = new google.visualization.Table(document.getElementById('div_sga_tab'));;
prompt       table.draw(data, {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}});;
prompt	}

---------------------------------------------------
-- SGA chart end
---------------------------------------------------

---------------------------------------------------
-- Instance activity chart
---------------------------------------------------
prompt     function drawInstActChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('string', 'Statistic name');;
prompt       data.addColumn('number', 'Value');;
prompt       data.addColumn('number', 'Avg/sec');;
prompt       data.addColumn({type:'string',label:'Avg/sec formatted',role:'tooltip'});;
prompt 
prompt       data.addRows([
with snap as
(
  select snap_id,dbid,instance_number
    ,snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(snap_time,'YYYY')||','||to_char(to_number(to_char(snap_time,'MM'))-1)||','||to_char(snap_time,'DD,HH24,MI,SS') chart_dt
    ,round(((snap_time-lag(snap_time) over (partition by startup_time order by snap_id)))*24*60*60) ela_sec
    ,startup_time,snapshot_exec_time_s
  from stats$snapshot
  where snap_id between &&bsnap and &&esnap
  and dbid = (select dbid from v$database)
  and instance_number = (select instance_number from v$instance)
), stat as
(
select 
 snap_id,dbid,instance_number,chart_dt
,decode(name,'logons cumulative','logons','session logical reads','logical reads(blocks)','redo size','redo size(bytes)',name) stat_name
  ,case
    when lag(st.value) over (partition by st.statistic# order by snap_id) >  st.value then st.value
    else st.value-lag(st.value) over (partition by st.statistic# order by snap_id) 
   end value
 ,round(
  case
    when lag(st.value) over (partition by st.statistic# order by snap_id) >  st.value then st.value
    else st.value-lag(st.value) over (partition by st.statistic# order by snap_id) 
  end/ela_sec,2) value_per_sec
  ,row_number() over(order by snap_id desc,name desc) rn
from stats$sysstat st join snap  using(snap_id, dbid, instance_number)
where name in
  (
    'user commits'
    ,'user rollbacks'
    ,'user calls'
    ,'physical read total IO requests'
    ,'physical write total IO requests'
    ,'physical read total bytes'
    ,'physical write total bytes'    
    ,'session logical reads'
    ,'db block changes'
    ,'redo size'
    ,'logons cumulative'
    ,'parse count (total)'
    ,'parse count (hard)'
    ,'execute count'
  )
order by snap_id,statistic#
)
select --chart_dt,stat_name,value,value_per_sec,
  '[new Date('||chart_dt||'),'||
  ''''||stat_name||''','||
  value||','||
  value_per_sec||','||
  ''''||stat_name||': '|| 
  case 
    when value_per_sec > 1024*1024 then round(value_per_sec/1024/1024,2)||'M' 
    when value_per_sec > 1024 then round(value_per_sec/1024,2)||'K'
    else trim(to_char(value_per_sec,'9990.00'))
  end||''''||
  ']'||case when rn=1 then '' else ',' end
from stat
where value is not null
order by snap_id,stat_name;



prompt       ]);;

prompt		var dashboard = new google.visualization.Dashboard(document.getElementById('div_inst_activ'));;
prompt
prompt        var filter = new google.visualization.ControlWrapper({
prompt          controlType: 'CategoryFilter',
prompt          containerId: 'div_inst_activ_filter',
prompt          options: {
prompt            filterColumnLabel: 'Statistic name',
prompt			  ui: {
prompt		        allowMultiple: false,
prompt				allowNone: false
prompt			  }
prompt          },
prompt			state: {selectedValues: ['logical reads(blocks)']}
prompt        });;
prompt
prompt       var chart = new google.visualization.ChartWrapper({
prompt          chartType: 'LineChart',
prompt          containerId: 'div_inst_activ_chart',
prompt          options: {
prompt            	title: 'Instance activity (load profile)',
prompt            	backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt            	explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt            	titleTextStyle: {fontSize: 16, bold: true},
prompt            	focusTarget: 'category',
prompt            	legend: {position: 'right', textStyle: {fontSize: 12}},
prompt            	tooltip: {textStyle: {fontSize: 11}},
prompt            	hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt            	vAxis: {title: 'Value', textStyle: {fontSize: 10}, format: 'short'}
prompt				},
prompt		  	view: {columns: [0,3,4]}  
prompt        });;	
prompt		var table = new google.visualization.ChartWrapper({
prompt          chartType: 'Table',
prompt          containerId: 'div_inst_activ_tab',
prompt          options: {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}},
prompt		  view: {columns: [0,2,3,4]}  
prompt        });;	
prompt
prompt
prompt        dashboard.bind([filter], [chart, table]);;
prompt        dashboard.draw(data);;		
prompt 
prompt 	}

---------------------------------------------------
-- Instance activity chart end
---------------------------------------------------

---------------------------------------------------
-- Wait Class chart
---------------------------------------------------
prompt     function drawWClassChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('number', 'DB CPU');;
prompt       data.addColumn('number', 'background CPU');;
prompt       data.addColumn('number', 'Administrative');;
prompt       data.addColumn('number', 'Application');;
prompt       data.addColumn('number', 'Cluster');;
prompt       data.addColumn('number', 'Commit');;
prompt       data.addColumn('number', 'Concurrency');;
prompt       data.addColumn('number', 'Configuration');;
prompt       data.addColumn('number', 'Network');;
prompt       data.addColumn('number', 'Other');;
prompt       data.addColumn('number', 'Queueing');;
prompt       data.addColumn('number', 'Scheduler');;
prompt       data.addColumn('number', 'System I/O');;
prompt       data.addColumn('number', 'User I/O');;
prompt 
prompt       data.addRows([
with snap as
(
  select snap_id,dbid,instance_number
    ,snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(snap_time,'YYYY')||','||to_char(to_number(to_char(snap_time,'MM'))-1)||','||to_char(snap_time,'DD,HH24,MI,SS') chart_dt
    ,round(((snap_time-lag(snap_time) over (partition by startup_time order by snap_id)))*24*60*60) ela_sec
    ,startup_time,snapshot_exec_time_s
  from stats$snapshot
  where snap_id between &&bsnap and &&esnap
  and dbid = (select dbid from v$database)
  and instance_number = (select instance_number from v$instance)
),
stat_cpu as
(
SELECT snap_id,dbid,instance_number
  ,upper(stat_name) stat_name
  ,round((stm.value-lag(stm.value) over (partition by startup_time,tms.stat_name order by snap_id))/1000000,2) sec
FROM stats$sys_time_model stm join stats$time_model_statname tms using(stat_id)
join snap using(snap_id,dbid,instance_number)
where upper(stat_name) in('BACKGROUND CPU TIME','DB CPU')
),
stat as
(
  select snap_id,dbid,instance_number,wait_class,round((time_waited_micro-lag(time_waited_micro) over(partition by wait_class order by snap_id))/1e6,2) as time_waited_sec
  from
  (
    select
    snap_id,dbid,instance_number,e.wait_class,sum(time_waited_micro) as time_waited_micro
    FROM stats$system_event se join v$event_name e using (event_id)
      join snap using(snap_id,dbid,instance_number)
    where e.wait_class <> 'Idle'
    group by snap_id,dbid,instance_number,e.wait_class
  ) 
), 
chart_data_waits as
(
select 
  *
from stat 
pivot
  (
    sum(time_waited_sec)
    for wait_class in
      (
        'Queueing' as "Queueing",
        'User I/O' as "User I/O",
        'Network' as "Network",
        'Application' as "Application",
        'Concurrency' as "Concurrency",
        'Administrative' as "Administrative",
        'Configuration' as "Configuration",
        'Scheduler' as "Scheduler",
        'Cluster' as "Cluster",
        'Other' as "Other",        
        'System I/O' as "System I/O",
        'Commit' as "Commit"
      )
  ) 
where "Commit" is not null
)
,chart_data_cpu as
(
select *
from stat_cpu
pivot
  (
    max(sec)
    for (stat_name) in
    (
      'DB CPU' as "DB CPU",
      'BACKGROUND CPU TIME' as "background CPU"
    )
  )
where "DB CPU" is not null
)
select 
  '[new Date('||chart_dt||'),'||
  c."DB CPU"||','||
  c."background CPU"||','||
  w."Administrative"||','||
  w."Application"||','||
  nvl(w."Cluster",0)||','||
  w."Commit"||','||
  w."Concurrency"||','||
  w."Configuration"||','||
  w."Network"||','||
  w."Other"||','||
  w."Queueing"||','||
  w."Scheduler"||','||
  w."System I/O"||','||
  w."User I/O"||
  ']'||case when rn=1 then '' else ',' end
from chart_data_waits w join chart_data_cpu c using(snap_id,dbid,instance_number) join snap using(snap_id,dbid,instance_number)
order by snap_id;

prompt       ]);;
prompt 
prompt       var options = {
prompt            isStacked: true,
prompt            title: 'Time by wait class (per snapshot)',
prompt            backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt            explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt            titleTextStyle: {fontSize: 16, bold: true},
prompt            focusTarget: 'category',
prompt            legend: {position: 'right', textStyle: {fontSize: 12}},
prompt            tooltip: {textStyle: {fontSize: 11}},
prompt            hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt            vAxis: {title: 'Time in seconds', textStyle: {fontSize: 10}}
prompt       };;
prompt 
prompt       var chart = new google.visualization.AreaChart(document.getElementById('div_wait_class_chart'));;
prompt       chart.draw(data, options);;
prompt       var table = new google.visualization.Table(document.getElementById('div_wait_class_tab'));;
prompt       table.draw(data, {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}});;
prompt	}

---------------------------------------------------
-- Wait Class chart end
---------------------------------------------------
---------------------------------------------------
-- Event hist chart 
---------------------------------------------------
prompt     function drawWaitEvHistChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('string', 'Event name');;
prompt       data.addColumn('number', '< 1ms');;
prompt       data.addColumn('number', '< 2ms');;
prompt       data.addColumn('number', '< 4ms');;
prompt       data.addColumn('number', '< 8ms');;
prompt       data.addColumn('number', '< 16ms');;
prompt       data.addColumn('number', '< 32ms');;
prompt       data.addColumn('number', '< 64ms');;
prompt       data.addColumn('number', '< 128ms');;
prompt       data.addColumn('number', '< 256ms');;
prompt       data.addColumn('number', '< 0.5s');;
prompt       data.addColumn('number', '< 1s');;
prompt       data.addColumn('number', '< 2s');;
prompt       data.addColumn('number', '< 4s');;
prompt       data.addColumn('number', '< 8s');;
prompt       data.addColumn('number', '< 16s');;
prompt       data.addColumn('number', '> 16s');;
prompt 
prompt       data.addRows([
with snap as
(
  select snap_id,dbid,instance_number
    ,snap_time
    --,row_number() over (order by snap_id desc) rn
    ,to_char(snap_time,'YYYY')||','||to_char(to_number(to_char(snap_time,'MM'))-1)||','||to_char(snap_time,'DD,HH24,MI,SS') chart_dt
    ,round(((snap_time-lag(snap_time) over (partition by startup_time order by snap_id)))*24*60*60) ela_sec
    ,startup_time,snapshot_exec_time_s
  from stats$snapshot
  where snap_id between &&bsnap and &&esnap
  and dbid = (select dbid from v$database)
  and instance_number = (select instance_number from v$instance)
),
ev_hist as
(
SELECT snap_id,dbid,instance_number
  ,row_number() over (order by snap_id desc,name desc) rn
  ,e.name event_name
  ,eh.wait_time_milli wtmil
  --,wait_count
  --,eh.wait_count-lag(eh.wait_count) over(partition by snap.startup_time,event_id,eh.wait_time_milli order by snap_id) wait_count
  ,Round(Ratio_To_Report(wait_count) over(PARTITION BY snap_id,instance_number,event_id)*100,2) pct 
FROM  stats$event_histogram eh join v$event_name e using (event_id)
join snap using(snap_id,dbid,instance_number)
where 
  e.name in
	(
		'log file sync'
		,'db file sequential read'
		,'log file parallel write'
		,'db file scattered read'
		,'direct path read'
		,'direct path read temp'
		,'direct path write temp'
		,'db file parallel read'
		,'flashback log file write'
		,'control file sequential read'		
	)
),
chart_data as
(
select snap_id,dbid,instance_number
  ,row_number() over (order by snap_id desc,event_name desc) rn
  ,event_name
  ,max(decode(wtmil,1,pct,0)) as "< 1ms"
  ,max(decode(wtmil,2,pct,0)) as "< 2ms"
  ,max(decode(wtmil,4,pct,0)) as "< 4ms"
  ,max(decode(wtmil,8,pct,0)) as "< 8ms"
  ,max(decode(wtmil,16,pct,0)) as "< 16ms"
  ,max(decode(wtmil,32,pct,0)) as "< 32ms"
  ,max(decode(wtmil,64,pct,0)) as "< 64ms"
  ,max(decode(wtmil,128,pct,0)) as "< 128ms"
  ,max(decode(wtmil,256,pct,0)) as "< 256ms"
  ,max(decode(wtmil,512,pct,0)) as "< 0.5s"
  ,max(decode(wtmil,1024,pct,0)) as "< 1s"
  ,max(decode(wtmil,2048,pct,0)) as "< 2s"
  ,max(decode(wtmil,4096,pct,0)) as "< 4s"
  ,max(decode(wtmil,8192,pct,0)) as "< 8s"
  ,max(decode(wtmil,16384,pct,0)) as "< 16s"
  ,max(case when wtmil > 16384 then pct else 0 end) as "> 16s"  
from ev_hist 
group by snap_id,dbid,instance_number,event_name
) 
select
  '[new Date('||chart_dt||'),'||
  ''''||event_name||''','||
  "< 1ms"||','||
  "< 2ms"||','||
  "< 4ms"||','||
  "< 8ms"||','||
  "< 16ms"||','||
  "< 32ms"||','||
  "< 64ms"||','||
  "< 128ms"||','||
  "< 256ms"||','||
  "< 0.5s"||','||
  "< 1s"||','||
  "< 2s"||','||
  "< 4s"||','||
  "< 8s"||','||
  "< 16s"||','||
  "> 16s"||
  ']'||case when rn=1 then '' else ',' end
from chart_data join snap using(snap_id,dbid,instance_number)
order by snap_id,event_name;

prompt       ]);;


prompt		var dashboard = new google.visualization.Dashboard(document.getElementById('div_event_hist'));;
prompt
prompt        var wclassCategory = new google.visualization.ControlWrapper({
prompt          controlType: 'CategoryFilter',
prompt          containerId: 'div_event_hist_filter',
prompt          options: {
prompt            filterColumnLabel: 'Event name',
prompt			ui: {
prompt				allowMultiple: false,
prompt				allowNone: false
prompt			}
prompt          },
prompt			state: {selectedValues: ['log file sync']}
prompt        });;
prompt
prompt       var chart = new google.visualization.ChartWrapper({
prompt          chartType: 'AreaChart',
prompt          containerId: 'div_event_hist_chart',
prompt          options: {
prompt				isStacked: 'percent',
prompt				title: 'Wait event histogram %',
prompt				backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt				explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt				titleTextStyle: {fontSize: 16, bold: true},
prompt				focusTarget: 'category',
prompt				legend: {position: 'right', textStyle: {fontSize: 12}},
prompt				tooltip: {textStyle: {fontSize: 11}},
prompt				hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt				vAxis: {title: 'Percent of waits (histogram)', textStyle: {fontSize: 10} , format: 'percent'}
prompt				},
prompt		  view: {columns: [0,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]}  
prompt        });;	
prompt
prompt		var table = new google.visualization.ChartWrapper({
prompt          chartType: 'Table',
prompt          containerId: 'div_event_hist_tab',
prompt          options: {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}},
prompt		  view: {columns: [0,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]}  
prompt        });;	
prompt
prompt        dashboard.bind([wclassCategory], [chart, table]);;
prompt        dashboard.draw(data);;		
prompt 
prompt 	}

---------------------------------------------------
-- Event hist chart end
---------------------------------------------------


---------------------------------------------------
-- Wait class hist chart 
---------------------------------------------------
prompt     function drawWaitClHistChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('string', 'Wait class');;
prompt       data.addColumn('number', '< 1ms');;
prompt       data.addColumn('number', '< 2ms');;
prompt       data.addColumn('number', '< 4ms');;
prompt       data.addColumn('number', '< 8ms');;
prompt       data.addColumn('number', '< 16ms');;
prompt       data.addColumn('number', '< 32ms');;
prompt       data.addColumn('number', '< 64ms');;
prompt       data.addColumn('number', '< 128ms');;
prompt       data.addColumn('number', '< 256ms');;
prompt       data.addColumn('number', '< 0.5s');;
prompt       data.addColumn('number', '< 1s');;
prompt       data.addColumn('number', '< 2s');;
prompt       data.addColumn('number', '< 4s');;
prompt       data.addColumn('number', '< 8s');;
prompt       data.addColumn('number', '< 16s');;
prompt       data.addColumn('number', '> 16s');;
prompt 
prompt       data.addRows([
with snap as
(
  select snap_id,dbid,instance_number
    ,snap_time
    --,row_number() over (order by snap_id desc) rn
    ,to_char(snap_time,'YYYY')||','||to_char(to_number(to_char(snap_time,'MM'))-1)||','||to_char(snap_time,'DD,HH24,MI,SS') chart_dt
    ,round(((snap_time-lag(snap_time) over (partition by startup_time order by snap_id)))*24*60*60) ela_sec
    ,startup_time,snapshot_exec_time_s
  from stats$snapshot
  where snap_id between &&bsnap and &&esnap
  and dbid = (select dbid from v$database)
  and instance_number = (select instance_number from v$instance)
),
ev_hist as
(
SELECT snap_id,dbid,instance_number
  ,wait_class
  ,wait_time_milli wtmil
  ,Round(Ratio_To_Report(wait_count) over(PARTITION BY snap_id,instance_number,wait_class)*100,2) pct
FROM (SELECT snap_id,dbid,instance_number
        ,e.wait_class
        ,eh.wait_time_milli 
        ,sum(wait_count) wait_count
      FROM  stats$event_histogram eh join v$event_name e using (event_id)
      where wait_class <> 'Idle'
      group by snap_id,dbid,instance_number
        ,e.wait_class
        ,eh.wait_time_milli
      )
join snap using(snap_id,dbid,instance_number)
),
chart_data as
(
select snap_id,dbid,instance_number
  ,wait_class
  ,row_number() over (order by snap_id desc,wait_class desc) rn
  ,max(decode(wtmil,1,pct,0)) as "< 1ms"
  ,max(decode(wtmil,2,pct,0)) as "< 2ms"
  ,max(decode(wtmil,4,pct,0)) as "< 4ms"
  ,max(decode(wtmil,8,pct,0)) as "< 8ms"
  ,max(decode(wtmil,16,pct,0)) as "< 16ms"
  ,max(decode(wtmil,32,pct,0)) as "< 32ms"
  ,max(decode(wtmil,64,pct,0)) as "< 64ms"
  ,max(decode(wtmil,128,pct,0)) as "< 128ms"
  ,max(decode(wtmil,256,pct,0)) as "< 256ms"
  ,max(decode(wtmil,512,pct,0)) as "< 0.5s"
  ,max(decode(wtmil,1024,pct,0)) as "< 1s"
  ,max(decode(wtmil,2048,pct,0)) as "< 2s"
  ,max(decode(wtmil,4096,pct,0)) as "< 4s"
  ,max(decode(wtmil,8192,pct,0)) as "< 8s"
  ,max(decode(wtmil,16384,pct,0)) as "< 16s"
  ,max(case when wtmil > 16384 then pct else 0 end) as "> 16s"
from ev_hist
group by snap_id,dbid,instance_number,wait_class
)
select  
  '[new Date('||chart_dt||'),'||
  ''''||wait_class||''','||
  "< 1ms"||','||
  "< 2ms"||','||
  "< 4ms"||','||
  "< 8ms"||','||
  "< 16ms"||','||
  "< 32ms"||','||
  "< 64ms"||','||
  "< 128ms"||','||
  "< 256ms"||','||
  "< 0.5s"||','||
  "< 1s"||','||
  "< 2s"||','||
  "< 4s"||','||
  "< 8s"||','||
  "< 16s"||','||
  "> 16s"||
  ']'||case when chart_data.rn=1 then '' else ',' end
from chart_data join snap using(snap_id,dbid,instance_number)
order by snap_id,wait_class;

prompt       ]);;


prompt		var dashboard = new google.visualization.Dashboard(document.getElementById('div_wclass_hist_filter'));;
prompt
prompt        var wclassCategory = new google.visualization.ControlWrapper({
prompt          controlType: 'CategoryFilter',
prompt          containerId: 'div_wclass_hist_filter',
prompt          options: {
prompt            filterColumnLabel: 'Wait class',
prompt			  ui: {
prompt				allowMultiple: false,
prompt				allowNone: false
prompt			  }
prompt          },
prompt			state: {selectedValues: ['User I/O']}
prompt        });;
prompt
prompt       var chart = new google.visualization.ChartWrapper({
prompt          chartType: 'AreaChart',
prompt          containerId: 'div_wclass_hist_chart',
prompt          options: {
prompt				isStacked: 'percent',
prompt				title: 'Wait class histogram %',
prompt				backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt				explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt				titleTextStyle: {fontSize: 16, bold: true},
prompt				focusTarget: 'category',
prompt				legend: {position: 'right', textStyle: {fontSize: 12}},
prompt				tooltip: {textStyle: {fontSize: 11}},
prompt				hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt				vAxis: {title: 'Percent of waits (histogram)', textStyle: {fontSize: 10} , format: 'percent'}
prompt				},
prompt		  view: {columns: [0,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]}  
prompt        });;	
prompt
prompt		var table = new google.visualization.ChartWrapper({
prompt          chartType: 'Table',
prompt          containerId: 'div_wclass_hist_tab',
prompt          options: {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}},
prompt		  view: {columns: [0,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]}  
prompt        });;	
prompt
prompt        dashboard.bind([wclassCategory], [chart, table]);;
prompt        dashboard.draw(data);;	
prompt 
prompt 	}
---------------------------------------------------
-- Wait class hist chart END
---------------------------------------------------


---------------------------------------------------
-- TOP SQLs chart 
---------------------------------------------------
prompt     function drawTopSQLChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn({type:'string',label:'sql_id'});;
prompt       data.addColumn('number', 'Executions');;
prompt       data.addColumn('number', 'Buffer gets');;
prompt       data.addColumn('number', 'Buf gets/exec');;
prompt       data.addColumn('number', 'CPU (sec)');;
prompt       data.addColumn('number', 'SQL CPU % of DB CPU');;
prompt       data.addColumn('number', 'DB CPU (total in snap)');;
prompt       data.addColumn('number', 'CPU/exec');;
prompt       data.addColumn('number', 'Elapsed (sec)');;
prompt       data.addColumn('number', 'Ela% of DB Time');;
prompt       data.addColumn('number', 'DB Time (total in snap)');;
prompt       data.addColumn('number', 'Ela/exec');;
prompt       data.addColumn('number', 'User I/O (sec)');;
prompt       data.addColumn('number', 'User I/O/exec');;
prompt       data.addColumn('number', 'Application (sec)');;
prompt       data.addColumn('number', 'Application/ exec');;
prompt       data.addColumn('number', 'Concurrency (sec)');;
prompt       data.addColumn('number', 'Concurrency/ exec');;
prompt       data.addColumn('number', 'PLSQL (sec)');;
prompt       data.addColumn('number', 'PLSQL/exec');;
prompt       data.addColumn('number', 'Rows (total)');;
prompt       data.addColumn('number', 'Rows/exec');;
prompt 
prompt       data.addRows([
with snap as
(
  select snap_id,dbid,instance_number
    ,snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(snap_time,'YYYY')||','||to_char(to_number(to_char(snap_time,'MM'))-1)||','||to_char(snap_time,'DD,HH24,MI,SS') chart_dt
    ,round(((snap_time-lag(snap_time) over (partition by startup_time order by snap_id)))*24*60*60) ela_snap_sec
    ,startup_time,snapshot_exec_time_s
    ,case when nvl(lag(startup_time) over(order by startup_time),startup_time) <> startup_time then 1 else 0 end restart
  from stats$snapshot
  where snap_id between &&bsnap and &&esnap
  and dbid = (select dbid from v$database)
  and instance_number = (select instance_number from v$instance)
),
stat_cpu as
(
select snap_id, dbid, instance_number,max(decode(stat_name,'DB CPU',sec,null)) as db_cpu, max(decode(stat_name,'DB TIME',sec,null)) as db_time
from
  (
    select snap_id,dbid,instance_number
      ,upper(stat_name) stat_name
      ,case
        when stm.value<lag(stm.value) over (partition by startup_time,tms.stat_name order by snap_id) then
          round((stm.value)/1000000,2)
        else
          round((stm.value-lag(stm.value) over (partition by startup_time,tms.stat_name order by snap_id))/1000000,2)
      end sec
    from stats$sys_time_model stm join stats$time_model_statname tms using(stat_id)
    join snap using(snap_id,dbid,instance_number)
    where stat_name in('DB time','DB CPU')
  )
  group by snap_id, dbid, instance_number
)
,
sqls as
(
  select snap_id,dbid,instance_number
    ,s.sql_id
    ,s.old_hash_value
    ,nvl(s.executions,0) execs
    ,nvl(s.buffer_gets,0) gets
    ,nvl(s.cpu_time,0) cpu
    ,nvl(s.elapsed_time,0) ela
    ,nvl(s.user_io_wait_time,0) user_io
    ,nvl(s.application_wait_time,0) appli
    ,nvl(s.concurrency_wait_time,0) concurr
    ,nvl(s.plsql_exec_time,0) plsql
    ,nvl(s.rows_processed,0) rows_p
    ,restart
    ,ela_snap_sec
    ,chart_dt
  FROM stats$sql_summary s join snap using(snap_id,dbid,instance_number)
),
sdiff as
(
select
  snap_id,dbid,instance_number,ela_snap_sec,chart_dt
  ,sql_id,old_hash_value
  ,case
    when execs < lag(execs) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when execs < lag(execs) over(partition by sql_id order by snap_id) and restart = 1 then execs
    else execs - lag(execs) over(partition by sql_id order by snap_id)
   end execs
  ,case
    when gets < lag(gets) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when gets < lag(gets) over(partition by sql_id order by snap_id) and restart = 1 then gets
    else gets - lag(gets) over(partition by sql_id order by snap_id)
   end gets
  ,case
    when cpu < lag(cpu) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when cpu < lag(cpu) over(partition by sql_id order by snap_id) and restart = 1 then cpu
    else cpu - lag(cpu) over(partition by sql_id order by snap_id)
   end cpu
  ,case
    when ela < lag(ela) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when ela < lag(ela) over(partition by sql_id order by snap_id) and restart = 1 then ela
    else ela - lag(ela) over(partition by sql_id order by snap_id)
   end ela
  ,case
    when user_io < lag(user_io) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when user_io < lag(user_io) over(partition by sql_id order by snap_id) and restart = 1 then user_io
    else user_io - lag(user_io) over(partition by sql_id order by snap_id)
   end user_io
  ,case
    when appli < lag(appli) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when appli < lag(appli) over(partition by sql_id order by snap_id) and restart = 1 then appli
    else appli - lag(appli) over(partition by sql_id order by snap_id)
   end appli
  ,case
    when concurr < lag(concurr) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when concurr < lag(concurr) over(partition by sql_id order by snap_id) and restart = 1 then concurr
    else concurr - lag(concurr) over(partition by sql_id order by snap_id)
   end concurr
  ,case
    when plsql < lag(plsql) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when plsql < lag(plsql) over(partition by sql_id order by snap_id) and restart = 1 then plsql
    else plsql - lag(plsql) over(partition by sql_id order by snap_id)
   end plsql
  ,case
    when rows_p < lag(rows_p) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when rows_p < lag(rows_p) over(partition by sql_id order by snap_id) and restart = 1 then rows_p
    else rows_p - lag(rows_p) over(partition by sql_id order by snap_id)
   end rows_p
from sqls
)
, sdiff2 as
(
select snap_id, dbid, instance_number,ela_snap_sec,chart_dt
  ,sql_id, old_hash_value
  ,execs
  ,gets
  ,round(gets/decode(execs,0,1,execs),2) gets_exec
  ,round(cpu/1000000,2) cpu_sec
  ,round(cpu/decode(execs,0,1,execs)/1000000,4) cpu_sec_exec
  ,round(ela/1000000,2) ela_sec
  --,ratio_to_report(ela) over (partition by snap_id) pct_of_total_ela
  ,round(ela/decode(execs,0,1,execs)/1000000,4) ela_sec_exec
  ,round(user_io/1000000,2) user_io_sec
  ,round(user_io/decode(execs,0,1,execs)/1000000,4) user_io_sec_exec
  ,round(appli/1000000,2) appli_sec
  ,round(appli/decode(execs,0,1,execs)/1000000,4) appli_sec_exec
  ,round(concurr/1000000,2) concurr_sec
  ,round(concurr/decode(execs,0,1,execs)/1000000,4) concurr_sec_exec
  ,round(plsql/1000000,2) plsql_sec
  ,round(plsql/decode(execs,0,1,execs)/1000000,4) plsql_sec_exec
  ,rows_p as rows_total
  ,round(rows_p/decode(execs,0,1,execs),2) rows_exec
  ,row_number() over (partition by snap_id order by ela desc) top_n
  --,row_number() over (order by snap_id,ela desc) rn
from sdiff
where execs is not null
),chart_data as
(
select
  --snap_id, dbid, instance_number,rn, top_n,  
  chart_dt
  ,snap_id
  ,nvl(sql_id,'Snap Total:') sql_id
  ,sum(execs) execs
  ,sum(gets) gets
  ,sum(gets_exec) gets_exec
  ,sum(cpu_sec) cpu_sec
  ,sum(cpu_sec_exec)   cpu_sec_exec
  ,sum(ela_sec) ela_sec
  ,sum(ela_sec_exec) ela_sec_exec
  ,sum(user_io_sec) user_io_sec
  ,sum(user_io_sec_exec) user_io_sec_exec
  ,sum(appli_sec) appli_sec
  ,sum(appli_sec_exec) appli_sec_exec 
  ,sum(concurr_sec) concurr_sec
  ,sum(concurr_sec_exec) concurr_sec_exec
  ,sum(plsql_sec) plsql_sec
  ,sum(plsql_sec_exec) plsql_sec_exec
  ,sum(rows_total) rows_total
  ,sum(rows_exec) rows_exec
  ,max(db_cpu) db_cpu
  ,max(db_time) db_time
from sdiff2 join stat_cpu using(snap_id,dbid,instance_number)
where top_n <= &&nTopSqls
group by rollup(chart_dt,snap_id,sql_id)
having grouping_id(chart_dt,snap_id,sql_id) <=1
order by snap_id,9
)
select
  decode(rownum,1,'',',')||
    '[new Date('||chart_dt||'),'||
  ''''||sql_id||''','||
  execs||','||
  gets||','||
  decode(sql_id,'Snap Total:',0,gets_exec)||','||
  cpu_sec||','||
  round(cpu_sec/db_cpu,4)*100 ||','||
  db_cpu||','||
  decode(sql_id,'Snap Total:',0,cpu_sec_exec)||','||
  ela_sec||','||
  round(ela_sec/db_time,4)*100 ||','||
  db_time||','||
  decode(sql_id,'Snap Total:',0,ela_sec_exec)||','||
  user_io_sec||','||
  decode(sql_id,'Snap Total:',0,user_io_sec_exec)||','||
  appli_sec||','||
  decode(sql_id,'Snap Total:',0,appli_sec_exec)||','||  
  concurr_sec||','||
  decode(sql_id,'Snap Total:',0,concurr_sec_exec)||','||
  plsql_sec||','||
  decode(sql_id,'Snap Total:',0,plsql_sec_exec)||','||
  rows_total||','||
  decode(sql_id,'Snap Total:',0,rows_exec)
  ||']' 
from chart_data;


prompt       ]);;



prompt
prompt		var chartView = new google.visualization.DataView(data);;
prompt		chartView.setRows(chartView.getFilteredRows([{column: 1, value: 'Snap Total:'}]));;
prompt		chartView.setColumns([0, 5, 9]);;
prompt
prompt       var chart = new google.visualization.ChartWrapper({
prompt          chartType: 'ColumnChart',
prompt          containerId: 'div_top_sqls_chart',
prompt			dataTable: chartView,
prompt          options: {
prompt				isStacked:true,
prompt				title: 'Top &&nTopSqls SQLs by elapsed time',
prompt				backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt				explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt				titleTextStyle: {fontSize: 16, bold: true},
prompt				focusTarget: 'category',
prompt				legend: {position: 'right', textStyle: {fontSize: 12}},
prompt				tooltip: {textStyle: {fontSize: 11}},
prompt				hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt				vAxis: {title: 'Top &&nTopSqls SQLs elapsed time (sec)', textStyle: {fontSize: 10}}
prompt				}
prompt        });;	
prompt		chart.draw();;
prompt
prompt		var dashboard = new google.visualization.Dashboard(document.getElementById('div_top_sqls'));
prompt
prompt      var filter = new google.visualization.ControlWrapper({
prompt          controlType: 'DateRangeFilter',
prompt          containerId: 'div_top_sqls_range',
prompt          options: {
prompt            filterColumnLabel: 'Snapshot',
prompt			  ui: {
prompt				step: 'hour'
prompt			  }
prompt          }
prompt      });;
prompt
prompt      var formatter = new google.visualization.PatternFormat('<a href="#{0}">{0}</a>');
prompt      formatter.format(data, [1]);
prompt
prompt      var sqlid_filter = new google.visualization.ControlWrapper({
prompt          controlType: 'StringFilter',
prompt          containerId: 'div_top_sqls_filter',
prompt          options: {
prompt            filterColumnLabel: 'sql_id'
prompt          }
prompt      });;
prompt 
prompt 
prompt		var table = new google.visualization.ChartWrapper({
prompt          chartType: 'Table',
prompt          containerId: 'div_top_sqls_tab',
prompt          options: {allowHtml: true, width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}},
prompt		  view: {columns: [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22]}  
prompt        });	
prompt
prompt      dashboard.bind([filter,sqlid_filter], [table]);;
prompt      dashboard.draw(data);;		
prompt 
prompt 	}
---------------------------------------------------
-- TOP SQLs chart END
---------------------------------------------------

prompt   </script>
---------------------------------------------------
-- CSS
---------------------------------------------------
prompt <style type="text/css">
prompt   body {font-family: Arial,Helvetica,Geneva,sans-serif; font-size:8pt; text-color: black; background-color: white;}
prompt   table.sql {font-size:8pt; color:#333366; width:70%; border-width: 2px; border-color: #000000; border-collapse: collapse; margin-left:10px;} 
prompt   th {border-width: 1px; background-color:#d9d9d9; padding: 3px; border-style: solid; border-color: #000000;} 
prompt   tr:nth-child(even) {background: #f2f2f2}
prompt   tr:nth-child(odd) {background: #FFFFFF}
prompt   tr:hover {color:black; background:#85d0fe;}
prompt   td {border-width: 1px; padding: 2px; border-style: solid; border-color: #000000; color:#000000;} 
prompt   th.gcharttab {font-size:8pt;font-weight:bold; background: linear-gradient(to top, #9494b8 0%, #c2c2d6 100%);}
prompt   td.gcharttab {font-size:8pt;}
prompt   h1 {font-size:16pt; font-weight:bold; text-decoration:underline; color:#333366; padding:10px 2px 1px 5px; text-align:center;}
prompt   h2 {font-size:12pt; font-weight:bold; text-decoration:underline; color:#333366; padding:10px 2px 1px 5px;}
prompt   h3 {font-size:10pt; font-weight:bold; text-decoration:underline; color:#333366; padding:10px 2px 1px 5px;}
prompt   pre {font:8pt monospace;Monaco,"Courier New",Courier;}
prompt   font.footnote {font-size:8pt; font-style:italic; color:#555;}
prompt   li.footnote {font-size:8pt; font-style:italic; color:#555;}
prompt   .google-visualization-table-table *  { font-size:8pt; }
prompt </style>
prompt </head>
---------------------------------------------------
-- BODY
---------------------------------------------------
prompt <body>
prompt <h1> Statspack report for database: &&db_n., instance: &&inst_n., interval: &&bdate - &&edate </h1>
prompt <h2> Database info </h2>
set markup html on head "" TABLE "class='sql' style='width:900px;'"
set pagesize 100
select d.name,d.dbid,to_char(d.created,'&&DT_FMT_ISO') created,i.instance_number as inst_id,i.host_name,d.platform_name,i.version,i.status,to_char(i.startup_time,'&&DT_FMT_ISO') startup_time
from v$database d,v$instance i;

set markup html on head "" TABLE "class='sql' style='width:300px;'"
select 'CPU sockets:' as host_property, cpu_socket_count_current as value from v$license union
select 'CPU cores:' as property, cpu_core_count_current as value from v$license union
select 'CPU threads:' as property, cpu_count_current as value from v$license union
select 'Physical mem (GB):',value/1024/1024/1024 From v$osstat where osstat_id=1008
;


set markup html on head "" TABLE "class='sql' style='width:600px;'"
select 'Begin snap:' as " ",snap_id,to_char(snap_time,'YYYY-MM-DD HH24:MI') snap_time,to_char((snap_time-startup_time) day(3) to second(0),'DDD HH24:MI:SS') uptime,value as sessions
from stats$snapshot join stats$sysstat ss using(snap_id,dbid,instance_number)
where snap_id=&&bsnap and ss.name='logons current'
union all
select 'End snap:' as " ",snap_id,to_char(snap_time,'YYYY-MM-DD HH24:MI') snap_time,to_char((snap_time-startup_time) day(3) to second(0),'DDD HH24:MI:SS') uptime,value 
from stats$snapshot join stats$sysstat ss using(snap_id,dbid,instance_number)
where snap_id=&&esnap and ss.name='logons current';


set pagesize 0
set markup html off
prompt <h2> Time model system stats </h2>
prompt <div id="div_time_model">
prompt 	<div id="div_time_model_filter" style='width:1200px;padding:10px'></div>
prompt 	<div id="div_time_model_chart" style='width:1200px; height: 400px'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below (time in minutes):</font>
prompt 	<div id="div_time_model_tab" style='width:1200px; height: 150px'></div>	
prompt </div>

prompt <h2> OS load </h2>
prompt <div id="div_os_load_chart" style='width:1200px; height: 400px'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below:</font>
prompt <div id="div_os_load_tab" style='width:1200px; height: 150px'></div>

prompt <h2> SGA stat </h2>
prompt <div id="div_sga_chart" style='width:1200px; height: 400px'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below:</font>
prompt <div id="div_sga_tab" style='width:1200px; height: 150px'></div>

prompt <h2> Instance activity (load profile) </h2>
prompt <div id="div_inst_activ">
prompt 	<div id="div_inst_activ_filter" style='width:1200px;padding:10px'></div>
prompt 	<div id="div_inst_activ_chart" style='width:1200px; height: 450px'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below:</font>
prompt 	<div id="div_inst_activ_tab" style='width:1200px; height: 150px'></div>	
prompt </div>


prompt <h2> Time by wait class </h2>
prompt <div id="div_wait_class_chart" style='width:1200px; height: 500px'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below (time in seconds):</font>
prompt <div id="div_wait_class_tab" style='width:1200px; height: 150px'></div>

prompt <h2> Wait class histograms (percent of total waits) </h2>
prompt <div id="div_wclass_hist">
prompt 	<div id="div_wclass_hist_filter" style='width:1200px;padding:10px'></div>
prompt 	<div id="div_wclass_hist_chart" style='width:1200px; height: 500px'></div>
prompt 	<div id="div_wclass_hist_tab" style='width:1200px; height: 150px'></div>	
prompt </div>

prompt <h2> Wait events (I/O related) histograms (percent of total waits) </h2>
prompt <div id="div_event_hist">
prompt 	<div id="div_event_hist_filter" style='width:1200px;padding:10px'></div>
prompt 	<div id="div_event_hist_chart" style='width:1200px; height: 500px'></div>
prompt 	<div id="div_event_hist_tab" style='width:1200px; height: 150px'></div>	
prompt </div>


prompt <h2> Top &&nTopSqls sqls by elapsed time </h2>
prompt <div id="div_top_sqls_chart" style='width:1200px; height: 500px'></div>
prompt <div id="div_top_sqls">
prompt 	<div id="div_top_sqls_range" style='width:1200px;padding-top:15px;'></div>
prompt 	<div id="div_top_sqls_filter" style='width:1200px;padding-top:10px;padding-bottom:10px;'></div>
prompt 	<div id="div_top_sqls_tab" style='width:95%; height: 350px'></div>	
prompt </div>


prompt <h2> List of SQL Text </h2>
prompt <ul>
prompt	<li>SQL text truncated to first 4000 characters</li>
prompt </ul>

set pagesize 40000
set markup html on head "" TABLE "class='sql' style='width:95%;'"
col sql_id entmap off
with snap as
(
  select snap_id,dbid,instance_number
    ,snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(snap_time,'YYYY')||','||to_char(to_number(to_char(snap_time,'MM'))-1)||','||to_char(snap_time,'DD,HH24,MI,SS') chart_dt
    ,round(((snap_time-lag(snap_time) over (partition by startup_time order by snap_id)))*24*60*60) ela_snap_sec
    ,startup_time,snapshot_exec_time_s
    ,case when nvl(lag(startup_time) over(order by startup_time),startup_time) <> startup_time then 1 else 0 end restart
  from stats$snapshot
  where snap_id between &&bsnap and &&esnap
  and dbid = (select dbid from v$database)
  and instance_number = (select instance_number from v$instance)
),
sqls as
(
  select snap_id,dbid,instance_number
    ,s.sql_id
    ,s.old_hash_value
    ,nvl(s.executions,0) execs
    ,nvl(s.buffer_gets,0) gets
    ,nvl(s.cpu_time,0) cpu
    ,nvl(s.elapsed_time,0) ela
    ,nvl(s.user_io_wait_time,0) user_io
    ,nvl(s.application_wait_time,0) appli
    ,nvl(s.concurrency_wait_time,0) concurr
    ,nvl(s.plsql_exec_time,0) plsql
    ,nvl(s.rows_processed,0) rows_p
    ,restart
    ,ela_snap_sec
    ,chart_dt
  FROM stats$sql_summary s join snap using(snap_id,dbid,instance_number)
),
sdiff as
(
select
  snap_id,dbid,instance_number ,ela_snap_sec,chart_dt
  ,sql_id,old_hash_value
  ,case
    when execs < lag(execs) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when execs < lag(execs) over(partition by sql_id order by snap_id) and restart = 1 then execs
    else execs - lag(execs) over(partition by sql_id order by snap_id)
   end execs
  ,case
    when gets < lag(gets) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when gets < lag(gets) over(partition by sql_id order by snap_id) and restart = 1 then gets
    else gets - lag(gets) over(partition by sql_id order by snap_id)
   end gets
  ,case
    when cpu < lag(cpu) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when cpu < lag(cpu) over(partition by sql_id order by snap_id) and restart = 1 then cpu
    else cpu - lag(cpu) over(partition by sql_id order by snap_id)
   end cpu
  ,case
    when ela < lag(ela) over(partition by sql_id order by snap_id) and restart = 0 then 0
    when ela < lag(ela) over(partition by sql_id order by snap_id) and restart = 1 then ela
    else ela - lag(ela) over(partition by sql_id order by snap_id)
   end ela
from sqls
)
, sdiff2 as
(
select snap_id, dbid, instance_number,ela_snap_sec,chart_dt
  ,sql_id, old_hash_value
  ,gets
  ,round(gets/decode(execs,0,1,execs),2) gets_exec
  ,round(cpu/1000000,2) cpu_sec
  ,round(cpu/decode(execs,0,1,execs)/1000000,4) cpu_sec_exec
  ,round(ela/1000000,2) ela_sec
  ,round(ela/decode(execs,0,1,execs)/1000000,4) ela_sec_exec
  ,row_number() over (partition by snap_id order by ela desc) top_n
from sdiff
where execs is not null
),sql_ids
as(
select
  distinct sql_id
from sdiff2 
where top_n <= &&nTopSqls
)
select 
	'<div id="'||sql_id||'">'||sql_id||'</div>' sql_id
	,listagg(sql_text,'') within group(order by piece) as sql_text
from stats$sqltext
where sql_id in (select sql_id from sql_ids) and piece <= 61 /*trunc sql_text to 4000 chars*/
group by sql_id
order by sql_id;
set markup html off

prompt </body>
prompt </html>
prompt 

spool off

set termout on
prompt ==================================================================
prompt Generated report: &&MAINREPORTFILE
prompt ==================================================================
exit;