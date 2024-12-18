/*
 * Script for AWR snapshots analysis
 * Run as user with select privileges on DBA_HIST% and V$ views
 * https://github.com/TomaszKaniaX/dba_toolbox/blob/master/awr_trends_charts.sql
 * Author: Tomasz Kania
 * Ver: 0.03
 * inspired by Carlos Sierra: https://carlos-sierra.net/2014/07/28/free-script-to-generate-a-line-chart-on-html/
*/

set linesize 2000 pagesize 0 long 32000 longchunksize 32000
set termout off
set trimspool on echo off feedback off 
set verify off
set define '&'
set serveroutput on size unlimited
set sqlblanklines on

--defines 
col global_name new_val db_n noprint
col instance_name new_val inst_name noprint
col instance_number new_val inst_num noprint
col dbid_current new_val dbid noprint
select global_name from global_name;
select instance_name,trim(instance_number) as instance_number from v$instance;
select dbid as dbid_current from v$database;

--avoid comma as decimal separator in outputs
alter session set nls_numeric_characters='.,';


col bsnap new_val bsnap noprint
col esnap new_val esnap noprint

var bsnap number
var esnap number
var dbid number
var inst_id number
var nTopEvents number
var nTopSqls number


col bdate new_val bdate noprint
col edate new_val edate noprint
def DT_FMT_REP="YYYY-MM-DD"
def DT_FMT_ISO="YYYY-MM-DD HH24:MI"
var bdate varchar2(20)
var edate varchar2(20)


whenever sqlerror exit
set termout on

declare
  v_mgmt_lic varchar2(100);
begin
  select upper(value) into v_mgmt_lic from v$parameter where lower(name) = 'control_management_pack_access';
  if v_mgmt_lic like 'DIAGNOSTIC%' then
    dbms_output.put_line('* Diagnostic Pack is enabled');
  else
    raise_application_error(-20999,'Diagnostic Pack is disabled - AWR is not available.'||chr(10)||'Consider using statspack');
  end if;
end;
/


select 
  to_char(greatest(trunc(sysdate)-3,min(end_interval_time)),'&&DT_FMT_REP') as bdate, 
  to_char(least(trunc(sysdate),max(end_interval_time)),'&&DT_FMT_REP') as edate 
from dba_hist_snapshot;


col dbid form 999999999999
col inst_id form 99999
col db_name form A10
col host_name form A30
col db_unique_name form A20
col database_role form A16
set pagesize 10
prompt ==================================================================
prompt Available databases/instances in AWR repository
prompt ==================================================================
select distinct dbid,instance_number inst_id,db_name,host_name,db_unique_name,database_role 
from dba_hist_database_instance;
set pagesize 0

prompt
prompt ==================================================================
ACCEPT dbid  DEFAULT '&dbid'  PROMPT 'Select DBID  [&dbid]: '
ACCEPT inst_id  DEFAULT '&inst_num'  PROMPT 'Select Instance Number  [&inst_num]: '
prompt ==================================================================

select distinct 'Selected DB: '||db_unique_name as selected_db, db_unique_name as global_name from dba_hist_database_instance where dbid = &dbid and instance_number = &inst_id; 


declare 
  v_nSnaps number;
  v_OldestSnap date;
  v_NewestSnap date;
  v_date1 date;
  v_date2 date;
begin
  :dbid := &dbid;
  :inst_id := &inst_id;
  select count(*),min(end_interval_time), max(end_interval_time) into v_nSnaps,v_OldestSnap,v_NewestSnap from dba_hist_snapshot where dbid=:dbid and instance_number=:inst_id;  
  if v_nSnaps < 8 then
    raise_application_error(-20001,'Insufficient data in AWR repository. '||to_char(v_nSnaps)||' snapshosts available, at least 8 snapsthots are required');
  else
    select 
      greatest(trunc(sysdate)-3,min(end_interval_time)),
      least(trunc(sysdate),max(end_interval_time))
      into v_date1,v_date2  
    from dba_hist_snapshot
	where  dbid=:dbid and instance_number=:inst_id;
    :bdate := to_char(v_date1,'&&DT_FMT_ISO');
    :edate := to_char(v_date2,'&&DT_FMT_ISO');
   
    dbms_output.put_line('==================================================================');
    dbms_output.put_line('Snapshots available: '||to_char(v_nSnaps));
    dbms_output.put_line('Oldest snapshot: '||to_char(v_OldestSnap,'&&DT_FMT_REP HH24:MI'));
    dbms_output.put_line('Latest snapshot: '||to_char(v_NewestSnap,'&&DT_FMT_REP HH24:MI'));
    dbms_output.put_line('==================================================================');
  end if;
end;
/


prompt ==================================================================
ACCEPT bdate  DEFAULT '&bdate'  PROMPT 'Enter start date as &&DT_FMT_REP [&bdate]: '
ACCEPT edate  DEFAULT '&edate'  PROMPT 'Enter end date as &&DT_FMT_REP [&edate]: '
ACCEPT nTopSqls DEFAULT '5'     PROMPT 'Enter number of top SQLs per snapshot [5]: '
ACCEPT nTopEvents DEFAULT '5'   PROMPT 'Enter number of top Wait events per snapshot [5]: '
prompt ==================================================================

begin 
  :nTopSqls := &&nTopSqls ;
  :nTopEvents := &&nTopEvents ;
end;
/  


declare
  v_bsnap number;
  v_esnap number;
  v_nSnaps number;
begin
  select min(snap_id) into v_bsnap 
  from
  (
    select snap_id,lag(snap_id) over(order by end_interval_time) prev_snap,lead(snap_id) over(order by end_interval_time) next_snap,end_interval_time from dba_hist_snapshot where dbid=:dbid and instance_number=:inst_id
  ) 
  where 
    end_interval_time >= to_date('&&bdate','&&DT_FMT_REP')
    --and prev_snap is not null 
    and next_snap is not null;

  select max(snap_id) into v_esnap 
  from
  (
    select snap_id,lag(snap_id) over(order by end_interval_time) prev_snap,lead(snap_id) over(order by end_interval_time) next_snap,end_interval_time from dba_hist_snapshot where dbid=:dbid and instance_number=:inst_id 
  ) 
  where 
    end_interval_time < to_date('&&edate','&&DT_FMT_REP')+1
    and snap_id > v_bsnap;

  select count(*) into v_nSnaps
  from dba_hist_snapshot
  where snap_id between v_bsnap and v_esnap
	and dbid=&dbid and instance_number=&inst_id;
  
  if v_nSnaps < 7 then
    Dbms_Output.Put_Line('bsnap:'||v_bsnap);
    Dbms_Output.Put_Line('esnap:'||v_esnap);
    raise_application_error(-20002,'Insufficient AWR data in selected range. '||to_char(v_nSnaps)||' snapshosts available, at least 7 usable snapsthots are required');
  else
    :bsnap := v_bsnap;
    :esnap := v_esnap; 
    dbms_output.put_line('Analyzing '||to_char(v_nSnaps)||' snapshots');
  end if;
end;
/

whenever sqlerror continue

prompt Generating report, it may take few minutes.... Please wait...
prompt
set termout off

var stime number
var etime number

begin
  :stime := dbms_utility.get_time();
end;
/

def REPTITLE="AWR trends report for &&db_n"

def MAINREPORTFILE=awr_trends_&&db_n._&&inst_num._&&bdate._&&edate..html
spool &&MAINREPORTFILE

prompt <html>
prompt <!-- AWR reports/graphs -->
prompt <!-- https://github.com/TomaszKaniaX/dba_toolbox/blob/master/awr_trends_charts.sql -->
prompt <!-- Author: Tomasz Kania -->
prompt <head>
prompt   <title>&&REPTITLE.</title>

---------------------------------------------------
-- GoogleChart JS
---------------------------------------------------
prompt   <script type="text/javascript" src="https://www.gstatic.com/charts/loader.js"></script>
prompt     <script type="text/javascript">
prompt       google.charts.load('current', {'packages':['table', 'corechart', 'controls']});;
prompt       google.charts.setOnLoadCallback(drawDBLoadChart);;  
prompt       google.charts.setOnLoadCallback(drawTimeModelChart);;  
prompt       google.charts.setOnLoadCallback(drawOSLoadChart);; 
prompt       google.charts.setOnLoadCallback(drawSGAChart);; 
prompt       google.charts.setOnLoadCallback(drawIOMBSFuncChart);; 
prompt       google.charts.setOnLoadCallback(drawInstActChart);;
prompt       google.charts.setOnLoadCallback(drawWClassChart);;
prompt       google.charts.setOnLoadCallback(drawWClassChartSingle);;
prompt       google.charts.setOnLoadCallback(drawTopWaitsChart);;
prompt       google.charts.setOnLoadCallback(drawTopWaitsTab);;
prompt       google.charts.setOnLoadCallback(drawWaitEvHistChart);;
prompt       google.charts.setOnLoadCallback(drawWaitClHistChart);;
prompt       google.charts.setOnLoadCallback(drawTopSQLChart);;
prompt 
prompt 

spool off
set termout on
prompt Gathering database load statistics...
set termout off
spool &&MAINREPORTFILE append

---------------------------------------------------
-- DB Load chart
---------------------------------------------------
prompt     function drawDBLoadChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('string', 'Process type');;
prompt       data.addColumn('number', 'CPU Cores');;
prompt       data.addColumn('number', 'CPU Threads');;
prompt       data.addColumn('number', 'DB CPU (%)');;
prompt       data.addColumn('number', 'DB Time (%)');;
prompt       data.addColumn('number', 'Elapsed (min)');;
prompt       data.addColumn('number', 'DB CPU (min)');;
prompt       data.addColumn('number', 'DB Time (min)');;
prompt 
prompt       data.addRows([
with snap as
(
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),
stat as
(
select snap_id,snap_time,chart_dt
  ,rn
  ,stm.stat_name
  ,case when stm.stat_name like 'background%' then 'Background' else 'Foreground' end fg_bg
  ,ela_sec
  ,ost.value as cpu_cores
  ,ost2.value as cpu_threads
  ,case
    when lag(stm.value) over (partition by stm.stat_name order by snap_id) >  stm.value then round(stm.value/1000000,2)
    else round((stm.value-lag(stm.value) over (partition by stm.stat_name order by snap_id))/1000000,2)
   end sec  
from dba_hist_sys_time_model stm join snap using(snap_id,dbid,instance_number)
join dba_hist_osstat ost using(snap_id,dbid,instance_number)
join dba_hist_osstat ost2 using(snap_id,dbid,instance_number)
where stm.stat_name in('DB time','DB CPU','background cpu time','background elapsed time')
  and ost.stat_id = 16 /* NUM_CPU_CORES */
  and ost2.stat_id = 0 /* NUM_CPUS */
),
group_stat as
(
select snap_time,chart_dt,ela_sec,cpu_cores,cpu_threads,fg_bg,
sum(case when stat_name in('DB CPU','background cpu time') then sec else 0 end) as DB_CPU, 
sum(case when stat_name in('DB time','background elapsed time') then sec else 0 end) as DB_TIME
from stat
where ela_sec <> 0 
group by rollup(snap_time,chart_dt,ela_sec,cpu_cores,cpu_threads,fg_bg) 
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
  ,cpu_threads   
  ,round(DB_CPU/ela_sec,4) db_cpu_pct
  ,round(DB_TIME/ela_sec,4) db_time_pct
  ,round(ela_sec/60,2) ela_min
  ,round(DB_CPU/60,2) db_cpu_min
  ,round(DB_TIME/60,2) db_time_min  
from 
group_stat 
where ela_sec is not null 
  and cpu_cores is not null 
  and cpu_threads is not null 
  and chart_dt is not null
order by snap_time, nvl(fg_bg,'Total')
)
select 
  '[new Date('||chart_dt||'),'||
  ''''||fg_bg||''','||
  cpu_cores||','||
  cpu_threads||','||
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
prompt		  view: {columns: [0,2,3,4,5]}  
prompt        });;	
prompt
prompt		var table = new google.visualization.ChartWrapper({
prompt          chartType: 'Table',
prompt          containerId: 'div_time_model_tab',
prompt          options: {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}},
prompt		  view: {columns: [0,2,3,6,7,8,4,5]}  
prompt        });;	
prompt
prompt        dashboard.bind([wclassCategory], [chart, table]);;
prompt        dashboard.draw(data);;	
prompt 
prompt 	}
prompt

---------------------------------------------------
-- DB Load chart end
---------------------------------------------------

spool off
set termout on
prompt Gathering time model statistics...
set termout off
spool &&MAINREPORTFILE append

---------------------------------------------------
-- Time model details chart
---------------------------------------------------
prompt     function drawTimeModelChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('number', 'DB CPU');;
prompt       data.addColumn('number', 'sql execute elapsed time');;
prompt       data.addColumn('number', 'PL/SQL execution elapsed time');;
prompt       data.addColumn('number', 'PL/SQL compilation elapsed time');;
prompt       data.addColumn('number', 'parse time elapsed');;
prompt       data.addColumn('number', 'hard parse elapsed time');;
prompt       data.addColumn('number', 'failed parse elapsed time');;
prompt       data.addColumn('number', 'connection management call elapsed time');;
prompt       data.addColumn('number', 'inbound PL/SQL rpc elapsed time');;
prompt       data.addColumn('number', 'repeated bind elapsed time');;
prompt       data.addColumn('number', 'Java execution elapsed time');;
prompt       data.addColumn('number', 'sequence load elapsed time');;
prompt 
prompt       data.addRows([
with snap as
(
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),
stat as
(
select snap_id,dbid,instance_number
  ,snap_time,chart_dt
  ,rn
  ,stat_name
  ,ela_sec
  ,case
    when lag(stm.value) over (partition by stm.stat_name order by snap_id) >  stm.value then round(stm.value/1000000/60,2)
    else round((stm.value-lag(stm.value) over (partition by stm.stat_name order by snap_id))/1000000/60,2)
   end sec  
from dba_hist_sys_time_model stm
join snap using(snap_id,dbid,instance_number)
),
chart_data as
(
select snap_id, dbid, instance_number, chart_dt, rn, ela_sec, db_cpu, sql_exec, java_exec, plsql_exec, plsql_compil, parse_time, hard_parse, failed_parse, conn_mgmt, inbound_plsql_rpc, repeated_bind, seq_load 
from stat
  pivot(
    max(sec) for stat_name in
      (
        'DB CPU' as db_cpu,
        --'DB time',
        'sql execute elapsed time' as sql_exec,
        'PL/SQL execution elapsed time' as plsql_exec,
        'PL/SQL compilation elapsed time' as plsql_compil,
        'parse time elapsed' as parse_time,
        'hard parse elapsed time' as hard_parse,
        'failed parse elapsed time' as failed_parse,
        'connection management call elapsed time' as conn_mgmt,
        --'RMAN cpu time (backup/restore)',
        --'background cpu time',
        --'background elapsed time',
        --'failed parse (out of shared memory) elapsed time',
        --'hard parse (bind mismatch) elapsed time',
        --'hard parse (sharing criteria) elapsed time',
        'inbound PL/SQL rpc elapsed time' as inbound_plsql_rpc,
        'repeated bind elapsed time' as repeated_bind,
        'Java execution elapsed time' as java_exec,
        'sequence load elapsed time' as seq_load
      )
  )
where db_cpu is not null
order by snap_id
)
select
  '[new Date('||chart_dt||'),'||
  db_cpu||','|| 
  sql_exec||','|| 
  plsql_exec||','|| 
  plsql_compil||','|| 
  parse_time||','||
  hard_parse||','|| 
  failed_parse||','|| 
  conn_mgmt||','||
  inbound_plsql_rpc||','||
  repeated_bind||','||
  java_exec||','|| 
  seq_load||
  ']'||case when rn=1 then '' else ',' end
from chart_data
order by snap_id;

prompt       ]);;
prompt 
prompt       var options = {
prompt            isStacked: true,
prompt            title: 'Time model (DB Time breakdown)',
prompt            backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt            explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt            titleTextStyle: {fontSize: 16, bold: true},
prompt            focusTarget: 'category',
prompt            legend: {position: 'right', textStyle: {fontSize: 12}},
prompt            tooltip: {textStyle: {fontSize: 11}},
prompt            hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt            vAxis: {title: 'Time (minutes)', textStyle: {fontSize: 10}}
prompt       };;
prompt 
prompt     var chart = new google.visualization.AreaChart(document.getElementById('div_time_model_det_chart'));;
prompt     chart.draw(data, options);;
prompt     var table = new google.visualization.Table(document.getElementById('div_time_model_det_tab'));;
prompt     table.draw(data, {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}});;
prompt	}
prompt
---------------------------------------------------
-- Time model details chart end
---------------------------------------------------

spool off
set termout on
prompt Gathering OS load statistics...
set termout off
spool &&MAINREPORTFILE append

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
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),stat as
(
select 
snap_id,dbid,instance_number,stat_name,
case 
  when lag(o.value) over (partition by stat_id order by snap_id) > o.value then o.value
  else o.value-lag(o.value) over (partition by stat_id order by snap_id)
end val
from dba_hist_osstat o join snap using(snap_id, dbid, instance_number)
where o.stat_name in('IDLE_TIME','BUSY_TIME','USER_TIME','SYS_TIME','IOWAIT_TIME','LOAD','OS_CPU_WAIT_TIME')
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
prompt
---------------------------------------------------
-- OS load chart end
---------------------------------------------------

spool off
set termout on
prompt Gathering SGA statistics...
set termout off
spool &&MAINREPORTFILE append

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
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),sga_stat as
(
select snap_id,dbid,instance_number,rn,chart_dt,nvl(pool,name) pool,round(bytes/1024/1024) mb 
from dba_hist_sgastat join snap using(snap_id,dbid,instance_number)
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

spool off
set termout on
prompt Gathering database I/O statistics...
set termout off
spool &&MAINREPORTFILE append

---------------------------------------------------
-- I/O MB/s by func chart
---------------------------------------------------
prompt
prompt     function drawIOMBSFuncChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('number', 'ARCH');;
prompt       data.addColumn('number', 'Archive Manager');;
prompt       data.addColumn('number', 'Buffer Cache Reads');;
prompt       data.addColumn('number', 'DBWR');;
prompt       data.addColumn('number', 'Data Pump');;
prompt       data.addColumn('number', 'Direct Reads');;
prompt       data.addColumn('number', 'Direct Writes');;
prompt       data.addColumn('number', 'LGWR');;
prompt       data.addColumn('number', 'Others');;
prompt       data.addColumn('number', 'RMAN');;
prompt       data.addColumn('number', 'Recovery');;
prompt       data.addColumn('number', 'Smart Scan');;
prompt       data.addColumn('number', 'Streams AQ');;
prompt       data.addColumn('number', 'XDB');;
prompt 
prompt       data.addRows([

with snap as
(
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),iostat as
(
select 
  snap_id,dbid,instance_number,ela_sec,chart_dt,rn
  ,function_name
  --,small_read_megabytes, small_write_megabytes, large_read_megabytes, large_write_megabytes, small_read_reqs, small_write_reqs, large_read_reqs, large_write_reqs
  ,case
    when lag(small_read_megabytes) over (partition by function_id order by snap_id) > small_read_megabytes then small_read_megabytes
    else small_read_megabytes-lag(small_read_megabytes) over (partition by function_id order by snap_id)
   end small_read_megabytes
  ,case
    when lag(small_write_megabytes) over (partition by function_id order by snap_id) > small_write_megabytes then small_write_megabytes
    else small_write_megabytes-lag(small_write_megabytes) over (partition by function_id order by snap_id)
   end small_write_megabytes
  ,case
    when lag(large_read_megabytes) over (partition by function_id order by snap_id) > large_read_megabytes then large_read_megabytes
    else large_read_megabytes-lag(large_read_megabytes) over (partition by function_id order by snap_id)
   end large_read_megabytes
  ,case
    when lag(large_write_megabytes) over (partition by function_id order by snap_id) > large_write_megabytes then large_write_megabytes
    else large_write_megabytes-lag(large_write_megabytes) over (partition by function_id order by snap_id)
   end large_write_megabytes
  ,case
    when lag(small_read_reqs) over (partition by function_id order by snap_id) > small_read_reqs then small_read_reqs
    else small_read_reqs-lag(small_read_reqs) over (partition by function_id order by snap_id)
   end small_read_reqs
  ,case
    when lag(small_write_reqs) over (partition by function_id order by snap_id) > small_write_reqs then small_write_reqs
    else small_write_reqs-lag(small_write_reqs) over (partition by function_id order by snap_id)
   end small_write_reqs
  ,case
    when lag(large_read_reqs) over (partition by function_id order by snap_id) > large_read_reqs then large_read_reqs
    else large_read_reqs-lag(large_read_reqs) over (partition by function_id order by snap_id)
   end large_read_reqs
  ,case
    when lag(large_write_reqs) over (partition by function_id order by snap_id) > large_write_reqs then large_write_reqs
    else large_write_reqs-lag(large_write_reqs) over (partition by function_id order by snap_id)
   end large_write_reqs
FROM dba_hist_iostat_function
join snap using( snap_id,dbid,instance_number)
order by snap_id,function_name
), mbs_by_func as
(
select 
    snap_id,dbid,instance_number,chart_dt ,rn
    ,function_name  
    ,round((small_read_megabytes+small_write_megabytes+large_read_megabytes+large_write_megabytes)/ela_sec,2) mbs
    --,small_read_reqs+ small_write_reqs+ large_read_reqs+ large_write_reqs
from iostat
where small_read_megabytes is not null and ela_sec <> 0
)
select 
--  chart_dt,arch, archive_manager, buf_cache_reads, dbwr, data_pump, direct_reads, direct_writes, lgwr, others, rman, recovery, smart_scan, streams_aq, xdb
  '[new Date('||chart_dt||'),'||
  arch||','|| 
  archive_manager||','|| 
  buf_cache_reads||','|| 
  dbwr||','|| 
  data_pump||','|| 
  direct_reads||','|| 
  direct_writes||','|| 
  lgwr||','|| 
  others||','|| 
  rman||','|| 
  recovery||','|| 
  smart_scan||','|| 
  streams_aq||','|| 
  xdb||
  ']'||case when rn=1 then '' else ',' end
from mbs_by_func
  pivot(
    max(mbs) for function_name in
      (
        'ARCH' as arch,
        'Archive Manager' as archive_manager,
        'Buffer Cache Reads' as buf_cache_reads,
        'DBWR' as dbwr,
        'Data Pump' as data_pump,
        'Direct Reads' as direct_reads,
        'Direct Writes' as direct_writes,
        'LGWR' as lgwr,
        'Others' as others,
        'RMAN' as rman,
        'Recovery' as recovery,
        'Smart Scan' as smart_scan,
        'Streams AQ' as streams_aq,
        'XDB' as xdb
      )
  )
order by snap_id;

prompt       ]);;
prompt 
prompt       var options = {
prompt            isStacked: true,
prompt            title: 'I/O MB/s by I/O function',
prompt            backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt            explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt            titleTextStyle: {fontSize: 16, bold: true},
prompt            focusTarget: 'category',
prompt            legend: {position: 'right', textStyle: {fontSize: 12}},
prompt            tooltip: {textStyle: {fontSize: 11}},
prompt            hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt            vAxis: {title: 'MB/s', textStyle: {fontSize: 10} }
prompt       };;
prompt 
prompt       var chart = new google.visualization.AreaChart(document.getElementById('div_iombs_func_chart'));;
prompt       chart.draw(data, options);;
prompt	}
prompt

---------------------------------------------------
-- I/O MB/s by func chart
---------------------------------------------------

spool off
set termout on
prompt Gathering instance activity statistics...
set termout off
spool &&MAINREPORTFILE append

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
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
), stat as
(
select 
 snap_id,dbid,instance_number,chart_dt
,decode(stat_name,'logons cumulative','logons','session logical reads','logical reads(blocks)','redo size','redo size(bytes)',stat_name) stat_name
  ,case
    when lag(st.value) over (partition by st.stat_id order by snap_id) >  st.value then st.value
    else st.value-lag(st.value) over (partition by st.stat_id order by snap_id) 
   end value
 ,round(
  case
    when lag(st.value) over (partition by st.stat_id order by snap_id) >  st.value then st.value
    else st.value-lag(st.value) over (partition by st.stat_id order by snap_id) 
  end/ela_sec,2) value_per_sec
  ,row_number() over(order by snap_id desc,stat_name desc) rn
from dba_hist_sysstat st join snap using(snap_id, dbid, instance_number)
where ela_sec <> 0 and
  stat_name in
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
    ,'bytes sent via SQL*Net to client'
    ,'bytes received via SQL*Net from client'
    ,'table scan blocks gotten'
    ,'table scan rows gotten'
  )
order by snap_id,stat_id
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
prompt
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
prompt

---------------------------------------------------
-- Instance activity chart end
---------------------------------------------------

spool off
set termout on
prompt Gathering wait events statistics...
set termout off
spool &&MAINREPORTFILE append

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
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
    ,case when nvl(lag(startup_time) over(order by startup_time),startup_time) <> startup_time then 1 else 0 end restart
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),
stat_cpu as
(
SELECT snap_id,dbid,instance_number
  ,upper(stat_name) stat_name
  ,case 
      when value-lag(value) over (partition by startup_time,stat_name order by snap_id) > 0 then
         round((value-lag(value) over (partition by startup_time,stat_name order by snap_id))/1000000/60,2)
      else
         --round((value)/1000000/60,2)
	null
   end cpu_min
  --,round((value-lag(value) over (partition by startup_time,stat_name order by snap_id))/1000000/60,2) cpu_min
FROM dba_hist_sys_time_model
   join snap using(snap_id,dbid,instance_number)
where upper(stat_name) in('BACKGROUND CPU TIME','DB CPU')
   and snap.restart = 0 
),
stat as
(
  select snap_id,dbid,instance_number,wait_class
   ,case 
      when time_waited_micro-lag(time_waited_micro) over(partition by wait_class order by snap_id) > 0 then
         round((time_waited_micro-lag(time_waited_micro) over(partition by wait_class order by snap_id))/1e6/60,2)
      else
         --round(time_waited_micro/1e6/60,2)
	null
    end time_waited_min
   --,round((time_waited_micro-lag(time_waited_micro) over(partition by wait_class order by snap_id))/1e6/60,2) as time_waited_min
  from
  (
    select
      snap_id,dbid,instance_number,wait_class,sum(time_waited_micro) as time_waited_micro
    from dba_hist_system_event  
      join snap using(snap_id,dbid,instance_number)
    where wait_class <> 'Idle'
      and snap.restart = 0 
    group by snap_id,dbid,instance_number,wait_class
  ) 
), 
chart_data_waits as
(
select 
  *
from stat 
pivot
  (
    sum(time_waited_min)
    for wait_class in
      (
        'Queueing' as queueing,
        'User I/O' as user_io,
        'Network' as Network,
        'Application' as Application,
        'Concurrency' as Concurrency,
        'Administrative' as Administrative,
        'Configuration' as Configuration,
        'Scheduler' as Scheduler,
        'Cluster' as clust,
        'Other' as Other,        
        'System I/O' as system_io,
        'Commit' as Commit_
      )
  ) 
where user_io is not null
)
,chart_data_cpu as
(
select *
from stat_cpu
pivot
  (
    max(cpu_min)
    for (stat_name) in
    (
      'DB CPU' as DB_CPU,
      'BACKGROUND CPU TIME' as background_CPU
    )
  )
where DB_CPU is not null
)
select 
  '[new Date('||chart_dt||'),'||
  c.DB_CPU||','||
  c.background_CPU||','||
  w.Administrative||','||
  w.Application||','||
  nvl(w.Clust,0)||','||
  w.Commit_||','||
  w.Concurrency||','||
  w.Configuration||','||
  w.Network||','||
  w.Other||','||
  w.Queueing||','||
  w.Scheduler||','||
  w.System_io||','||
  w.user_io||
  ']'||case when rn=1 then '' else ',' end
from chart_data_waits w join chart_data_cpu c using(snap_id,dbid,instance_number) join snap using(snap_id,dbid,instance_number)
where snap.restart = 0 
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
prompt            vAxis: {title: 'Time in minutes', textStyle: {fontSize: 10}}
prompt       };;
prompt 
prompt       var chart = new google.visualization.AreaChart(document.getElementById('div_wait_class_chart'));;
prompt       chart.draw(data, options);;
prompt       var table = new google.visualization.Table(document.getElementById('div_wait_class_tab'));;
prompt       table.draw(data, {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}});;
prompt	}
prompt

---------------------------------------------------
-- Wait Class chart end
---------------------------------------------------

---------------------------------------------------
-- Wait Class [single] chart
---------------------------------------------------
prompt     function drawWClassChartSingle() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('string', 'Wait class');;
prompt       data.addColumn('number', 'Wait time (minutes)');;
prompt       data.addColumn('number', 'Wait time');;
prompt       data.addColumn({type:'string',label:'Wait time (formatted)',role:'tooltip'});;
prompt 
prompt       data.addRows([
with snap as
(
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
    ,case when nvl(lag(startup_time) over(order by startup_time),startup_time) <> startup_time then 1 else 0 end restart
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),
stat_cpu as
(
SELECT snap_id,dbid,instance_number
  ,upper(stat_name) stat_name
  ,case 
      when value-lag(value) over (partition by startup_time,stat_name order by snap_id) > 0 then
         round((value-lag(value) over (partition by startup_time,stat_name order by snap_id))/1000000/60,2)
      else
         --round((value)/1000000/60,2)
	null
   end cpu_min 
  --,round((value-lag(value) over (partition by startup_time,stat_name order by snap_id))/1000000/60,2) cpu_min
FROM dba_hist_sys_time_model
join snap using(snap_id,dbid,instance_number)
where upper(stat_name) in('BACKGROUND CPU TIME','DB CPU')
),
stat as
(
  select snap_id,dbid,instance_number,wait_class
     ,case 
      when time_waited_micro-lag(time_waited_micro) over(partition by wait_class order by snap_id) > 0 then
         round((time_waited_micro-lag(time_waited_micro) over(partition by wait_class order by snap_id))/1e6/60,2)
      else
         --round(time_waited_micro/1e6/60,2)
         null
    end time_waited_min  
    --,round((time_waited_micro-lag(time_waited_micro) over(partition by wait_class order by snap_id))/1e6/60,2) as time_waited_min
  from
  (
    select
      snap_id,dbid,instance_number,wait_class,sum(time_waited_micro) as time_waited_micro
    from dba_hist_system_event  
      join snap using(snap_id,dbid,instance_number)
    where wait_class <> 'Idle'
    group by snap_id,dbid,instance_number,wait_class
  ) 
), 
chart_data as
(
select 
  snap_id
  ,dbid
  ,instance_number 
  ,wait_class
  ,time_waited_min
  ,row_number() over (order by snap_id,wait_class) grn
from (
  select
    snap_id
    ,dbid
    ,instance_number 
    ,wait_class
    ,time_waited_min
  from stat 
  where time_waited_min is not null
  union all
  select
    snap_id
    ,dbid
    ,instance_number 
    ,stat_name
    ,cpu_min
  from stat_cpu
  where cpu_min is not null
  )   
)
select 
  decode(grn,1,'',',')||
  '[new Date('||chart_dt||'),'||
  ''''||w.wait_class||''','||
  w.time_waited_min||','||
  w.time_waited_min||','||
  ''''||w.wait_class||': '||cast(numtodsinterval(w.time_waited_min,'MINUTE')  as interval day(3) to second(0))||''']'
from chart_data w join snap using(snap_id,dbid,instance_number)
where restart = 0
order by snap_id,wait_class;


prompt       ]);;
prompt
prompt		var dashboard = new google.visualization.Dashboard(document.getElementById('div_wait_class_single_chart'));;
prompt
prompt        var filter = new google.visualization.ControlWrapper({
prompt          controlType: 'CategoryFilter',
prompt          containerId: 'div_wait_class_single_filter',
prompt          options: {
prompt            filterColumnLabel: 'Wait class',
prompt			  ui: {
prompt		        allowMultiple: false,
prompt				allowNone: false
prompt			  }
prompt          },
prompt			state: {selectedValues: ['User I/O']}
prompt        });;
prompt
prompt       var chart = new google.visualization.ChartWrapper({
prompt          chartType: 'LineChart',
prompt          containerId: 'div_wait_class_single_chart',
prompt          options: {
prompt            	title: 'Time by wait class (per snapshot)',
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
prompt          containerId: 'div_wait_class_single_tab',
prompt          options: {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}},
prompt		  view: {columns: [0,1,2,4]}  
prompt        });;	
prompt
prompt
prompt        dashboard.bind([filter], [chart, table]);;
prompt        dashboard.draw(data);;	
prompt
prompt	}
prompt

---------------------------------------------------
-- Wait Class [single] chart end
---------------------------------------------------



---------------------------------------------------
-- Top wait events chart
---------------------------------------------------
prompt     function drawTopWaitsChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;

declare
  type t_str_tab is table of varchar2(64);
  v_events t_str_tab;
  v_sqlstmt   varchar2(8000);
  v_pivot     varchar2(4000);
  v_dyn_cols  varchar2(4000);
  v_gchart_cols   varchar2(4000);
  v_cid           number;
  t_desctab      dbms_sql.desc_tab;
  v_colcnt       number;
  v_colval       varchar2(4000);
  v_rowcnt       number;
  v_gchart_data  varchar2(4000);

  cursor c_events is
    with snap as
    (
      select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
        ,cast(end_interval_time as date) as snap_time
        ,row_number() over (order by snap_id desc) rn
        ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
        ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
        ,startup_time
        ,case when nvl(lag(startup_time) over(order by startup_time),startup_time) <> startup_time then 1 else 0 end restart
      from dba_hist_snapshot
      where snap_id between :bsnap and :esnap
		and dbid = :dbid
		and instance_number = :inst_id
    ),
    stat_cpu as
    (
    select * from
    (
      select snap_id,dbid,instance_number
        ,upper(stat_name) stat_name
        ,value-lag(value) over (partition by startup_time,stat_name order by snap_id) as time_
      from dba_hist_sys_time_model
      join snap using(snap_id,dbid,instance_number)
      where stat_name in('DB time','DB CPU','background cpu time','background elapsed time')
    ) pivot (
        max(time_) for stat_name in
          (
            'DB TIME' as db_time,
            'DB CPU' as db_cpu,
            'BACKGROUND CPU TIME' as backgr_cpu,
            'BACKGROUND ELAPSED TIME' as backgr_ela
          )
      )
    ),
    stat as
    (
      select
        snap_id,dbid,instance_number
        ,wait_class
        ,event_name
        ,total_waits
        ,round(time_waited_micro/1e6,2) time_waited_sec
        ,avg_wait_time_ms
        ,row_number() over (partition by snap_id order by time_waited_micro desc) top_n_ev
        ,round(time_waited_micro/(db_time+backgr_ela)*100,2) pct_of_db_time
      from
      (
      select
        snap_id,dbid,instance_number
        ,event_name
        ,wait_class
        ,total_waits-lag(total_waits) over(partition by event_name order by snap_id) as total_waits
        ,time_waited_micro-lag(time_waited_micro) over(partition by event_name order by snap_id) as time_waited_micro
        ,case
          when total_waits-lag(total_waits) over(partition by event_name order by snap_id) = 0
            then 0
            else
              round((time_waited_micro-lag(time_waited_micro) over(partition by event_name order by snap_id))
              /(total_waits-lag(total_waits) over(partition by event_name order by snap_id))/1000,2)
        end avg_wait_time_ms
      from dba_hist_system_event
        join snap using(snap_id,dbid,instance_number)
      where wait_class <> 'Idle'
      union all
      select snap_id,dbid,instance_number,'DB CPU' as event_name,null as wait_class,null,db_cpu+backgr_cpu,null from stat_cpu join snap using(snap_id,dbid,instance_number)
      )
      join stat_cpu using(snap_id,dbid,instance_number)
    ),chart_data as
    (
    select snap_id,chart_dt,wait_class,event_name,total_waits,time_waited_sec,avg_wait_time_ms,pct_of_db_time,row_number() over(order by snap_id,top_n_ev) grn
      from stat join snap using(snap_id,dbid,instance_number)
    where
      time_waited_sec is not null
      and top_n_ev <= :nTopEvents
      and restart = 0
    order by snap_id,top_n_ev
    )
    select distinct event_name
    from chart_data
    ;
begin
  open c_events;
  fetch c_events bulk collect into v_events;
  close c_events;
  for i in 1..v_events.count
    loop
      v_pivot := v_pivot||''''||v_events(i)||''' as "'||substr(v_events(i),1,30)||'",';
      v_dyn_cols := v_dyn_cols||'"'||substr(v_events(i),1,30)||'",';
      --Dbms_Output.Put_Line('event: '||v_events(i));
      --v_gchart_cols := v_gchart_cols||'data.addColumn(''number'', '''||v_events(i)||''');;'||chr(10);
      Dbms_Output.Put_Line('data.addColumn(''number'', '''||v_events(i)||''');;');
    end loop;
  v_pivot := replace(rtrim(v_pivot,','),chr(38),'and');
  v_dyn_cols := replace(rtrim(v_dyn_cols,','),chr(38),'and');
  --dbms_output.put_line(v_pivot);
  --dbms_output.put_line(v_dyn_cols);
  --dbms_output.put_line(v_gchart_cols);
  dbms_output.put_line('');
  dbms_output.put_line('data.addRows([');

  v_sqlstmt := q'[    with snap as
    (
      select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
        ,cast(end_interval_time as date) as snap_time
        ,row_number() over (order by snap_id desc) rn
        ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
        ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
        ,startup_time
        ,case when nvl(lag(startup_time) over(order by startup_time),startup_time) <> startup_time then 1 else 0 end restart
      from dba_hist_snapshot
      where snap_id between :bsnap and :esnap
            and dbid = :dbid
			and instance_number = :inst_id
    ),
    stat_cpu as
    (
    select * from
    (
      SELECT snap_id,dbid,instance_number
        ,upper(stat_name) stat_name
        ,value-lag(value) over (partition by startup_time,stat_name order by snap_id) as time_
      FROM dba_hist_sys_time_model
      join snap using(snap_id,dbid,instance_number)
      where stat_name in('DB time','DB CPU','background cpu time','background elapsed time')
    ) pivot (
        max(time_) for stat_name in
          (
            'DB TIME' as db_time,
            'DB CPU' as db_cpu,
            'BACKGROUND CPU TIME' as backgr_cpu,
            'BACKGROUND ELAPSED TIME' as backgr_ela
          )
      )
    ),
    stat as
    (
      select
        snap_id,dbid,instance_number
        ,wait_class
        ,event_name
        ,total_waits
        ,round(time_waited_micro/1e6,2) time_waited_sec
        ,avg_wait_time_ms
        ,row_number() over (partition by snap_id order by time_waited_micro desc) top_n_ev
        ,round(time_waited_micro/(db_time+backgr_ela)*100,2) pct_of_db_time
      from
      (
      select
        snap_id,dbid,instance_number
        ,event_name
        ,wait_class
        ,total_waits-lag(total_waits) over(partition by event_name order by snap_id) as total_waits
        ,time_waited_micro-lag(time_waited_micro) over(partition by event_name order by snap_id) as time_waited_micro
        ,case
          when total_waits-lag(total_waits) over(partition by event_name order by snap_id) = 0
            then 0
            else
              round((time_waited_micro-lag(time_waited_micro) over(partition by event_name order by snap_id))
              /(total_waits-lag(total_waits) over(partition by event_name order by snap_id))/1000,2)
        end avg_wait_time_ms
      from dba_hist_system_event
        join snap using(snap_id,dbid,instance_number)
      where wait_class <> 'Idle'
      union all
      select snap_id,dbid,instance_number,'DB CPU' as event_name,null as wait_class,null,db_cpu+backgr_cpu,null from stat_cpu join snap using(snap_id,dbid,instance_number)
      )
      join stat_cpu using(snap_id,dbid,instance_number)
    ),chart_data as
    (
    select chart_dt,rn,event_name,time_waited_sec
      from stat join snap using(snap_id,dbid,instance_number)
    where
      time_waited_sec is not null
      and top_n_ev <= :nTopEvents
      and restart = 0
    order by snap_id,top_n_ev
    )
    select chart_dt,rn,]'||v_dyn_cols||q'[
    from chart_data
    pivot (max(time_waited_sec) for event_name in(]'||v_pivot||'))
    order by rn desc';

    --Dbms_Output.Put_Line(v_sqlstmt);
    v_cid := dbms_sql.open_cursor;

    dbms_sql.parse(
        v_cid,
        v_sqlstmt,
        dbms_sql.native
    );

    dbms_sql.bind_variable(v_cid, 'bsnap', :bsnap);
    dbms_sql.bind_variable(v_cid, 'esnap', :esnap);
    dbms_sql.bind_variable(v_cid, 'dbid', :dbid);
    dbms_sql.bind_variable(v_cid, 'inst_id', :inst_id);	
    dbms_sql.bind_variable(v_cid, 'nTopEvents', :nTopEvents);

    dbms_sql.describe_columns(
        v_cid,
        v_colcnt,
        t_desctab
    );
    for i in 1..v_colcnt loop
      dbms_sql.define_column(
          v_cid,
          i,
          v_colval,
          4000
        );
    end loop;

    v_rowcnt := dbms_sql.execute(v_cid);

    v_gchart_data := '';
    while ( dbms_sql.fetch_rows(v_cid) > 0 ) loop
      for i in 1..v_colcnt loop
        dbms_sql.column_value(
          v_cid,
          i,
          v_colval
        );
        --dbms_output.put_line(rpad(t_desctab(i).col_name,30)||': '|| v_colval);
        if t_desctab(i).col_name = 'CHART_DT' then
          v_gchart_data := v_gchart_data||'[new Date('||v_colval||')';
        elsif t_desctab(i).col_name = 'RN' then
          null;
        else
          v_gchart_data := v_gchart_data||','||nvl(v_colval,0);
        end if;
      end loop;
      v_gchart_data :=  v_gchart_data||']';
      Dbms_Output.Put_Line(v_gchart_data);
      v_gchart_data := ',';

    end loop;

    dbms_sql.close_cursor(v_cid);
exception
  when others then
  if dbms_sql.is_open(v_cid) then
    dbms_sql.close_cursor(v_cid);
  end if;
  raise;
end;
/



prompt       ]);;
prompt 
prompt       var options = {
prompt            isStacked: true,
prompt            title: 'Top &&nTopEvents wait events (per snapshot)',
prompt            backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt            explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt            titleTextStyle: {fontSize: 16, bold: true},
prompt            focusTarget: 'datum',
prompt            legend: {position: 'right', textStyle: {fontSize: 12}},
prompt            tooltip: {textStyle: {fontSize: 11}},
prompt            hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt            vAxis: {title: 'Time in seconds', textStyle: {fontSize: 10}}
prompt       };;
prompt 
prompt       var chart = new google.visualization.ColumnChart(document.getElementById('div_top_events_chart'));;
prompt       chart.draw(data, options);;
prompt	}
prompt

---------------------------------------------------
-- Top wait events chart end
---------------------------------------------------




---------------------------------------------------
-- Top wait events tab
---------------------------------------------------
prompt     function drawTopWaitsTab() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn('string', 'Wait class');;
prompt       data.addColumn('string', 'Event');;
prompt       data.addColumn('number', 'Total waits');;
prompt       data.addColumn('number', 'Wait time (sec)');;
prompt       data.addColumn('number', 'Avg. wait (ms)');;
prompt       data.addColumn('number', '% DB time');;
prompt 
prompt       data.addRows([
with snap as
(
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
    ,case when nvl(lag(startup_time) over(order by startup_time),startup_time) <> startup_time then 1 else 0 end restart
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),
stat_cpu as
(
select * from
(
  SELECT snap_id,dbid,instance_number
    ,upper(stat_name) stat_name
    --,round((value-lag(value) over (partition by startup_time,stat_name order by snap_id))/1000000,2) as time_sec
    ,value-lag(value) over (partition by startup_time,stat_name order by snap_id) as time_
  FROM dba_hist_sys_time_model
  join snap using(snap_id,dbid,instance_number)
  where stat_name in('DB time','DB CPU','background cpu time','background elapsed time')
) pivot (
    max(time_) for stat_name in
      (
        'DB TIME' as db_time,
        'DB CPU' as db_cpu,
        'BACKGROUND CPU TIME' as backgr_cpu,
        'BACKGROUND ELAPSED TIME' as backgr_ela
      )
  )
),
stat as
(
  select
    snap_id,dbid,instance_number
    ,wait_class
    ,event_name
    ,total_waits
    ,round(time_waited_micro/1e6,2) time_waited_sec
    ,avg_wait_time_ms
    ,row_number() over (partition by snap_id order by time_waited_micro desc) top_n_ev
    ,round(time_waited_micro/(db_time+backgr_ela)*100,2) pct_of_db_time
  from
  (
  select
    snap_id,dbid,instance_number
    ,event_name
    ,wait_class
    ,total_waits-lag(total_waits) over(partition by event_name order by snap_id) as total_waits
    ,time_waited_micro-lag(time_waited_micro) over(partition by event_name order by snap_id) as time_waited_micro
    ,case
      when total_waits-lag(total_waits) over(partition by event_name order by snap_id) = 0
        then 0
        else
          round((time_waited_micro-lag(time_waited_micro) over(partition by event_name order by snap_id))
          /(total_waits-lag(total_waits) over(partition by event_name order by snap_id))/1000,2)
     end avg_wait_time_ms
  from dba_hist_system_event
    join snap using(snap_id,dbid,instance_number)
  where wait_class <> 'Idle'
  union all
  select snap_id,dbid,instance_number,'DB CPU' as event_name,null as wait_class,null,db_cpu+backgr_cpu,null from stat_cpu join snap using(snap_id,dbid,instance_number)
  )
  join stat_cpu using(snap_id,dbid,instance_number)
),chart_data as
(
select snap_id,chart_dt,wait_class,event_name,total_waits,time_waited_sec,avg_wait_time_ms,pct_of_db_time,row_number() over(order by snap_id,top_n_ev) grn 
  from stat join snap using(snap_id,dbid,instance_number) 
where 
  time_waited_sec is not null
  and top_n_ev <= :nTopEvents
  and restart = 0
order by snap_id,top_n_ev
)
select 
  decode(grn,1,'',',')||
    '[new Date('||chart_dt||'),'||
  ''''||wait_class||''','||
  ''''||event_name||''','||
  total_waits||','||
  time_waited_sec||','||  
  avg_wait_time_ms||','||
  pct_of_db_time
  ||']' 
from chart_data;


prompt       ]);;
prompt 
prompt       var table = new google.visualization.Table(document.getElementById('div_top_events_tab'));;
prompt       table.draw(data, {width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}});;
prompt	}
prompt

---------------------------------------------------
-- Top wait events end
---------------------------------------------------

spool off
set termout on
prompt Gathering wait time histograms...
set termout off
spool &&MAINREPORTFILE append

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
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    --,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),
ev_hist as
(
select snap_id,dbid,instance_number,rn,event_name,wtmil,wait_count
,Round(Ratio_To_Report(wait_count) over(PARTITION BY snap_id,instance_number,event_id)*100,2) pct
from(
select snap_id,dbid,instance_number
  ,row_number() over (order by snap_id desc,event_name desc) rn
  ,event_id
  ,event_name
  ,wait_time_milli wtmil
  --,wait_count
  ,wait_count-lag(wait_count) over(partition by snap.startup_time,event_id,wait_time_milli order by snap_id) wait_count
  --,Round(Ratio_To_Report(wait_count) over(PARTITION BY snap_id,instance_number,event_id)*100,2) pct 
from dba_hist_event_histogram 
  join snap using(snap_id,dbid,instance_number)
where 
  event_name in
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
)
),
chart_data as
(
select snap_id,dbid,instance_number
  ,row_number() over (order by snap_id desc,event_name desc) rn
  ,event_name
  ,sum(case when wtmil <= 1 then pct else 0 end) as "< 1ms"
  ,sum(decode(wtmil,2,pct,0)) as "< 2ms"
  ,sum(decode(wtmil,4,pct,0)) as "< 4ms"
  ,sum(decode(wtmil,8,pct,0)) as "< 8ms"
  ,sum(decode(wtmil,16,pct,0)) as "< 16ms"
  ,sum(decode(wtmil,32,pct,0)) as "< 32ms"
  ,sum(decode(wtmil,64,pct,0)) as "< 64ms"
  ,sum(decode(wtmil,128,pct,0)) as "< 128ms"
  ,sum(decode(wtmil,256,pct,0)) as "< 256ms"
  ,sum(decode(wtmil,512,pct,0)) as "< 0.5s"
  ,sum(decode(wtmil,1024,pct,0)) as "< 1s"
  ,sum(decode(wtmil,2048,pct,0)) as "< 2s"
  ,sum(decode(wtmil,4096,pct,0)) as "< 4s"
  ,sum(decode(wtmil,8192,pct,0)) as "< 8s"
  ,sum(decode(wtmil,16384,pct,0)) as "< 16s"
  ,sum(case when wtmil > 16384 then pct else 0 end) as "> 16s"  
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

prompt    ]);;
prompt
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
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_sec
    ,startup_time
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),
ev_hist as
(
select snap_id,dbid,instance_number,wait_class,wtmil
,Round(Ratio_To_Report(wait_count) over(PARTITION BY snap_id,instance_number,wait_class)*100,2) pct
from 
( 
SELECT snap_id,dbid,instance_number
  ,wait_class
  ,wait_time_milli wtmil
  --,wait_count
  ,wait_count-lag(wait_count) over(partition by snap.startup_time,wait_class,wait_time_milli order by snap_id) wait_count
  --,Round(Ratio_To_Report(wait_count) over(PARTITION BY snap_id,instance_number,wait_class)*100,2) pct
FROM (SELECT snap_id,dbid,instance_number
        ,wait_class
        --,wait_class_id
        ,wait_time_milli
        ,sum(wait_count) wait_count
      FROM dba_hist_event_histogram
      where wait_class <> 'Idle'
      group by snap_id,dbid,instance_number
        ,wait_class
        ,wait_time_milli
      )
join snap using(snap_id,dbid,instance_number)
)
),
chart_data as
(
select snap_id,dbid,instance_number
  ,wait_class
  ,row_number() over (order by snap_id desc,wait_class desc) rn
  ,sum(case when wtmil <= 1 then pct else 0 end) as "< 1ms"
  ,sum(decode(wtmil,2,pct,0)) as "< 2ms"
  ,sum(decode(wtmil,4,pct,0)) as "< 4ms"
  ,sum(decode(wtmil,8,pct,0)) as "< 8ms"
  ,sum(decode(wtmil,16,pct,0)) as "< 16ms"
  ,sum(decode(wtmil,32,pct,0)) as "< 32ms"
  ,sum(decode(wtmil,64,pct,0)) as "< 64ms"
  ,sum(decode(wtmil,128,pct,0)) as "< 128ms"
  ,sum(decode(wtmil,256,pct,0)) as "< 256ms"
  ,sum(decode(wtmil,512,pct,0)) as "< 0.5s"
  ,sum(decode(wtmil,1024,pct,0)) as "< 1s"
  ,sum(decode(wtmil,2048,pct,0)) as "< 2s"
  ,sum(decode(wtmil,4096,pct,0)) as "< 4s"
  ,sum(decode(wtmil,8192,pct,0)) as "< 8s"
  ,sum(decode(wtmil,16384,pct,0)) as "< 16s"
  ,sum(case when wtmil > 16384 then pct else 0 end) as "> 16s"
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

spool off
set termout on
prompt Gathering top &&nTopSqls SQL statements...
set termout off
spool &&MAINREPORTFILE append

---------------------------------------------------
-- TOP SQLs chart 
---------------------------------------------------
prompt     function drawTopSQLChart() {
prompt       var data = new google.visualization.DataTable();;
prompt       data.addColumn('datetime', 'Snapshot');;
prompt       data.addColumn({type:'string',label:'sql_id'});;
--prompt       data.addColumn({type:'string',label:'sql_text',role:'tooltip'});;
prompt       data.addColumn({type:'string',label:'PHV'});;
prompt       data.addColumn({type:'string',label:'User'});;
prompt       data.addColumn({type:'string',label:'module'});;
prompt       data.addColumn({type:'string',label:'action',role:'tooltip'});;
prompt       data.addColumn('number', 'Executions');;
prompt       data.addColumn('number', 'Buffer gets');;
prompt       data.addColumn('number', 'Buf gets/exec');;
prompt       data.addColumn('number', 'CPU (sec)');;
prompt       data.addColumn('number', 'SQL CPU % of DB CPU');;
prompt       data.addColumn('number', 'DB CPU (total in snap)');;
prompt       data.addColumn('number', 'CPU/exec');;
prompt       data.addColumn('number', 'Elapsed (sec)');;
prompt       data.addColumn('number', 'SQL ela % of DB time');;
prompt       data.addColumn('number', 'DB Time (total in snap)');;
prompt       data.addColumn('number', 'Ela/exec');;
prompt       data.addColumn('number', 'User I/O (sec)');;
prompt       data.addColumn('number', 'User I/O/exec');;
prompt       data.addColumn('number', 'Application (sec)');;
prompt       data.addColumn('number', 'Appli./exec');;
prompt       data.addColumn('number', 'Concurrency (sec)');;
prompt       data.addColumn('number', 'Concur./exec');;
prompt       data.addColumn('number', 'PLSQL (sec)');;
prompt       data.addColumn('number', 'PLSQL/exec');;
prompt       data.addColumn('number', 'Rows (total)');;
prompt       data.addColumn('number', 'Rows/exec');;
prompt 
prompt       data.addRows([
with snap as
(
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_snap_sec
    ,startup_time
    ,case when nvl(lag(startup_time) over(order by startup_time),startup_time) <> startup_time then 1 else 0 end restart
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),
stat_cpu as
(
select snap_id, dbid, instance_number,max(decode(stat_name,'DB CPU',sec,null)) as db_cpu, max(decode(stat_name,'DB TIME',sec,null)) as db_time
from
  (
    select snap_id,dbid,instance_number
      ,upper(stat_name) stat_name
      ,case
        when stm.value<lag(stm.value) over (partition by startup_time,stat_name order by snap_id) then
          round((stm.value)/1000000,2)
        else
          round((stm.value-lag(stm.value) over (partition by startup_time,stat_name order by snap_id))/1000000,2)
      end sec
    from dba_hist_sys_time_model stm
    join snap using(snap_id,dbid,instance_number)
    where stat_name in('DB time','DB CPU') and ela_snap_sec <> 0
  )
  group by snap_id, dbid, instance_number
)
,
sqls as
(
  select snap_id,dbid,instance_number
    ,sql_id
    ,parsing_schema_name
    ,replace(module,'''','') module
    ,replace(action,'''','') action
    ,plan_hash_value
    ,executions_delta execs
    ,buffer_gets_delta gets
    ,cpu_time_delta cpu
    ,elapsed_time_delta ela
    ,iowait_delta user_io
    ,apwait_delta appli
    ,ccwait_delta concurr
    ,plsexec_time_delta plsql
    ,rows_processed_delta rows_p
    ,ela_snap_sec
    ,chart_dt
  FROM dba_hist_sqlstat  join snap using(snap_id,dbid,instance_number)
),
sdiff as
(
select snap_id, dbid, instance_number,ela_snap_sec,chart_dt
  ,sql_id, plan_hash_value,module,action,parsing_schema_name
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
  ,row_number() over (partition by snap_id order by ela desc) top_n_ela
  ,row_number() over (partition by snap_id order by cpu desc) top_n_cpu
  --,row_number() over (order by snap_id,ela desc) rn
from sqls
where execs is not null 
),chart_data as
(
select
  --snap_id, dbid, instance_number,rn, top_n,  
  chart_dt
  ,snap_id
  ,nvl(sql_id,'Snap Total:') sql_id
  ,nvl(plan_hash_value,0) plan_hash_value
  ,nvl(parsing_schema_name,'[null]') parsing_schema_name
  ,nvl(module,'[null]') module
  ,nvl(action,'[null]') action
   /*
   ,grouping(chart_dt)
   ,grouping(snap_id)
   ,grouping(sql_id)
   ,grouping(module)
   ,grouping(plan_hash_value)
   ,grouping(parsing_schema_name)
   */
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
from sdiff join stat_cpu using(snap_id,dbid,instance_number)
where top_n_ela <= :nTopSqls or top_n_cpu <= :nTopSqls
  and db_cpu is not null
group by rollup(chart_dt,snap_id,sql_id,plan_hash_value,parsing_schema_name,module,action)
having ( grouping(chart_dt) = 0 and grouping(snap_id) = 0 and grouping(sql_id) = 0 and grouping(module) = 0 and grouping(action) = 0 and grouping(plan_hash_value) = 0 and grouping(parsing_schema_name) = 0)
  or ( grouping(chart_dt) = 0 and grouping(snap_id) = 0 and grouping(sql_id) = 1 )
order by snap_id,13
)
select 
  decode(rownum,1,'',',')||
    '[new Date('||chart_dt||'),'||
  ''''||sql_id||''','||
  --''''||replace(replace(replace((select dbms_lob.substr(sql_text,200,1) from dba_hist_sqltext where sql_id = chart_data.sql_id and rownum <=1),'''','`'),chr(10),''),chr(13),'')||''','||
  ''''||plan_hash_value||''','||
  ''''||parsing_schema_name||''','||    
  ''''||module||''','||
  ''''||action||''','||  
  execs||','||
  gets||','||
  decode(sql_id,'Snap Total:',0,gets_exec)||','||
  cpu_sec||','||
  round(cpu_sec/decode(db_cpu,0,0.000001,db_cpu),4)*100 ||','||
  db_cpu||','||
  decode(sql_id,'Snap Total:',0,cpu_sec_exec)||','||
  ela_sec||','||
  round(ela_sec/decode(db_time,0,0.00001,db_time),4)*100 ||','||
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
prompt		chartView.setColumns([0, 9, 13]);;
prompt
prompt       var chart = new google.visualization.ChartWrapper({
prompt          chartType: 'ColumnChart',
prompt          containerId: 'div_top_sqls_chart',
prompt			dataTable: chartView,
prompt          options: {
prompt				isStacked:false,
prompt				title: 'Top &&nTopSqls SQLs by elapsed/CPU time',
prompt				backgroundColor: {fill: '#ffffff', stroke: '#0077b3', strokeWidth: 1},
prompt				explorer: {actions: ['dragToZoom', 'rightClickToReset'], axis:'horizontal', maxZoomIn: 0.2},
prompt				titleTextStyle: {fontSize: 16, bold: true},
prompt				focusTarget: 'category',
prompt				legend: {position: 'right', textStyle: {fontSize: 12}},
prompt				tooltip: {textStyle: {fontSize: 11}},
prompt				hAxis: {slantedText:true, slantedTextAngle:45, textStyle: {fontSize: 10}},
prompt				vAxis: {title: 'Top &&nTopSqls SQLs elapsed/CPU time (sec)', textStyle: {fontSize: 10}}
prompt				}
prompt        });;	
prompt		chart.draw();;
prompt
prompt		var dashboard = new google.visualization.Dashboard(document.getElementById('div_top_sqls'));;
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
prompt      var formatter = new google.visualization.PatternFormat('<a href="#{0}">{0}</a>');;
prompt      formatter.format(data, [1]);;
prompt
prompt      var sqlid_filter = new google.visualization.ControlWrapper({
prompt          controlType: 'StringFilter',
prompt          containerId: 'div_top_sqls_filter',
prompt          options: {
prompt            filterColumnLabel: 'sql_id'
prompt          }
prompt      });;
prompt 
prompt		var snap_filter = new google.visualization.ControlWrapper({
prompt			controlType: 'StringFilter',
prompt			containerId: 'div_top_sqls_snap_filter',
prompt			options: {
prompt				filterColumnLabel: 'Snapshot',
prompt				matchType: 'any',
prompt				useFormattedValue: true
prompt			}
prompt		});;
prompt 
prompt		var table = new google.visualization.ChartWrapper({
prompt          chartType: 'Table',
prompt          containerId: 'div_top_sqls_tab',
prompt          options: {allowHtml: true, width: '100%', height: '100%',cssClassNames:{headerCell:'gcharttab'}},
prompt		  view: {columns: [0,1,2,3,4,5,6,8,9,10,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]}  
prompt        });;	
prompt
prompt      dashboard.bind([sqlid_filter,snap_filter], [table]);;
prompt      dashboard.draw(data);;	
prompt
prompt      google.visualization.events.addListener(chart, 'select', selectBarSnapHandler);;
prompt      
prompt      function selectBarSnapHandler() {
prompt      var selection = chart.getChart().getSelection();;
prompt      if (selection) {
prompt          try {
prompt            var selDate = chartView.getFormattedValue(selection[0].row, 0);
prompt            snap_filter.setState({'value': selDate});;
prompt            snap_filter.draw();;
prompt          }
prompt          catch(err){
prompt            snap_filter.setState({'value': null});;
prompt            snap_filter.draw();;
prompt          }
prompt        }
prompt      }
prompt      
prompt      resetFilters = function() {
prompt        snap_filter.setState({'value': null});;
prompt        sqlid_filter.setState({'value': null});;
prompt        snap_filter.draw();;
prompt        sqlid_filter.draw();;
prompt      }	
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
prompt   tr:hover {color:black; background:#e6f2ff;}
prompt   td {border-width: 1px; padding: 2px; border-style: solid; border-color: #000000; color:#000000;} 
prompt   th.gcharttab {font-size:8pt;font-weight:bold; background: linear-gradient(to top, #9494b8 0%, #c2c2d6 100%);}
prompt   td.gcharttab {font-size:8pt;}
prompt   h1 {font-size:16pt; font-weight:bold; text-decoration:underline; color:#333366; padding:10px 2px 1px 5px; text-align:center;}
prompt   h2 {font-size:12pt; font-weight:bold; text-decoration:underline; color:#333366; padding:10px 2px 1px 5px;}
prompt   h3 {font-size:10pt; font-weight:bold; text-decoration:underline; color:#333366; padding:10px 2px 1px 5px;}
prompt   pre {font:8pt monospace;Monaco,"Courier New",Courier;}
prompt   font.footnote {font-size:8pt; font-style:italic; color:#555;}
prompt   li.footnote {font-size:8pt; font-style:italic; color:#555;}
prompt   a.toc:link, a.toc:visited {font-size:10pt; font-weight:bold; text-decoration:none; color:#333366;}
prompt   a.toc:hover {font-size:10pt; font-weight:bold; text-decoration:underline; color:#333366; background-color:#eeeef6}
prompt   a.fnnav:link, a.fnnav:visited {font-size:8pt; font-weight:bold; text-decoration:none; color:#333366;font-style:italic;}
prompt   a.fnnav:hover {font-size:8pt; font-weight:bold; text-decoration:underline; color:#333366; background-color:#eeeef6;font-style:italic;}
prompt   div.tab1200 {width:1200px; resize: vertical; overflow:auto;}
prompt   div.tab100pct {width:100%; resize: vertical; overflow:auto;}
prompt   .google-visualization-table-table *  { font-size:8pt; }
prompt </style>
prompt </head>
---------------------------------------------------
-- BODY
---------------------------------------------------
prompt <body>
prompt <h1> AWR trends report for database: &&db_n., instance: &&inst_num., interval: &&bdate - &&edate </h1>
prompt <h2> Database info </h2>
set markup html on head "" TABLE "class='sql' style='width:900px;'"
set pagesize 100
select d.name,d.dbid,to_char(d.created,'&&DT_FMT_ISO') created,i.instance_number as inst_id,i.host_name,d.platform_name,i.version,i.status,to_char(i.startup_time,'&&DT_FMT_ISO') startup_time
from v$database d,v$instance i;

set markup html on head "" TABLE "class='sql' style='width:300px;'"
select 'CPU sockets:' as host_property, cpu_socket_count_current as value from v$license union
select 'CPU cores:' as property, cpu_core_count_current as value from v$license union
select 'CPU threads:' as property, cpu_count_current as value from v$license union
select 'Physical mem (GB):',round(value/1024/1024/1024) From v$osstat where osstat_id=1008
;


set markup html on head "" TABLE "class='sql' style='width:600px;'"
select 'Begin snap:' as " ",snap_id,to_char(end_interval_time,'YYYY-MM-DD HH24:MI') snap_time,to_char((end_interval_time-startup_time) day(3) to second(0),'DDD HH24:MI:SS') uptime,value as sessions
from dba_hist_snapshot join dba_hist_sysstat ss using(snap_id,dbid,instance_number)
where snap_id=:bsnap and ss.stat_name='logons current'
union all
select 'Begin snap:' as " ",snap_id,to_char(end_interval_time,'YYYY-MM-DD HH24:MI') snap_time,to_char((end_interval_time-startup_time) day(3) to second(0),'DDD HH24:MI:SS') uptime,value as sessions
from dba_hist_snapshot join dba_hist_sysstat ss using(snap_id,dbid,instance_number)
where snap_id=:esnap and ss.stat_name='logons current';

set pagesize 0
set markup html off

prompt <h2 id="h_toc"> Reports list </h2>
prompt <ul>
prompt  <li><a class="toc" href="#h_time_model_stats">Time model system statistics</a></li> 
prompt  <li><a class="toc" href="#h_time_model_det">Time model system stats (DB Time details)</a></li> 
prompt  <li><a class="toc" href="#h_os_load">OS Load</a></li> 
prompt  <li><a class="toc" href="#h_instance_activity">Instance activity</a></li> 
prompt  <li><a class="toc" href="#h_wait_class_time">Time waited (by wait class - stacked)</a></li> 
prompt  <li><a class="toc" href="#h_wait_class_time_single">Time waited (by wait class - single)</a></li> 
prompt  <li><a class="toc" href="#h_top_events">Top &&nTopEvents wait events</a></li> 
prompt  <li><a class="toc" href="#h_wait_class_hist">Wait class histograms</a></li> 
prompt  <li><a class="toc" href="#h_io_wait_ev_hist">IO wait events histograms</a></li> 
prompt  <li><a class="toc" href="#h_sga_stat">SGA pool sizes</a></li> 
prompt  <li><a class="toc" href="#h_iombs_func">I/O MB/s by I/O function</a></li> 
prompt  <li><a class="toc" href="#h_top_n_sqls">Top &&nTopSqls SQLS by elapsed time and CPU time</a></li> 
prompt  <li><a class="toc" href="#h_sql_text">List of SQL texts</a></li> 
prompt </ul>


prompt <h2 id="h_time_model_stats"> Time model system stats </h2>
prompt <div id="div_time_model">
prompt 	<div id="div_time_model_filter" style='width:1200px;padding:10px;'></div>
prompt 	<div id="div_time_model_chart" style='width:1200px; height: 400px;'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below (time in minutes):</font>
prompt 	<div id="div_time_model_tab" class="tab1200" style='height: 150px;'></div>	
prompt </div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

prompt <h2 id="h_time_model_det"> Time model system stats (DB Time details) </h2>
prompt <div id="div_time_model_det_chart" style='width:1200px; height: 400px;'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below (time in minutes):</font>
prompt <div id="div_time_model_det_tab" class="tab1200" style='height: 150px;'></div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

prompt <h2 id="h_os_load"> OS load </h2>
prompt <div id="div_os_load_chart" style='width:1200px; height: 400px;'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below:</font>
prompt <div id="div_os_load_tab" class="tab1200" style='height: 150px;'></div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

prompt <h2 id="h_instance_activity"> Instance activity (load profile) </h2>
prompt <div id="div_inst_activ">
prompt 	<div id="div_inst_activ_filter" style='width:1200px;padding:10px;'></div>
prompt 	<div id="div_inst_activ_chart" style='width:1200px; height: 450px;'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below:</font>
prompt 	<div id="div_inst_activ_tab" class="tab1200" style='height: 150px;'></div>	
prompt </div>
prompt <a class="fnnav" href="#h_toc">back to top</a>


prompt <h2 id="h_wait_class_time"> Time by wait class (stacked) </h2>
prompt <div id="div_wait_class_chart" style='width:1200px; height: 500px;'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below (time in minutes):</font>
prompt <div id="div_wait_class_tab" class="tab1200" style='height: 150px;'></div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

prompt <h2 id="h_wait_class_time_single"> Time by wait class (single) </h2>
prompt <div id="div_wait_class_single">
prompt 	<div id="div_wait_class_single_filter" style='width:1200px;padding:10px;'></div>
prompt 	<div id="div_wait_class_single_chart" style='width:1200px; height: 500px;'></div>
prompt 	<div id="div_wait_class_single_tab" class="tab1200" style='height: 150px;'></div>	
prompt </div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

prompt <h2 id="h_top_events"> Top &&nTopEvents wait events </h2>
prompt <div id="div_top_events_chart" style='width:1200px; height: 650px;'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below (time in seconds):</font>
prompt <div id="div_top_events_tab" class="tab1200" style='height: 250px;'></div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

prompt <h2 id="h_wait_class_hist"> Wait class histograms (percent of total waits) </h2>
prompt <div id="div_wclass_hist">
prompt 	<div id="div_wclass_hist_filter" style='width:1200px;padding:10px;'></div>
prompt 	<div id="div_wclass_hist_chart" style='width:1200px; height: 500px;'></div>
prompt 	<div id="div_wclass_hist_tab" class="tab1200" style='height: 150px;'></div>	
prompt </div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

prompt <h2 id="h_io_wait_ev_hist"> Wait events (I/O related) histograms (percent of total waits) </h2>
prompt <div id="div_event_hist">
prompt 	<div id="div_event_hist_filter" style='width:1200px;padding:10px;'></div>
prompt 	<div id="div_event_hist_chart" style='width:1200px; height: 500px;'></div>
prompt 	<div id="div_event_hist_tab" class="tab1200" style='height: 150px;'></div>	
prompt </div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

prompt <h2 id="h_sga_stat"> SGA stat </h2>
prompt <div id="div_sga_chart" style='width:1200px; height: 400px;'></div>
prompt <font class="footnote">Graph note: drag to zoom, right click to reset. <br> Raw tabular data below:</font>
prompt <div id="div_sga_tab" class="tab1200" style='height: 150px;'></div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

prompt <h2 id="h_iombs_func"> I/O MB/s by I/O function  </h2>
prompt <div id="div_iombs_func_chart" style='width:1200px; height: 450px'></div>
prompt <a class="fnnav" href="#h_toc">back to top</a>


prompt <h2 id="h_top_n_sqls"> Top &&nTopSqls sqls by elapsed/CPU time </h2>
prompt <ul>
prompt <li class="footnote">Filtered &&nTopSqls top sqls by CPU time and &&nTopSqls top sqls by elapsed time </li>
prompt </ul>
prompt <div id="div_top_sqls_chart" style='width:1200px; height: 500px'></div>
prompt <div id="div_top_sqls">
prompt <ul>
prompt <li class="footnote">Graph note: drag to zoom, right click to reset</li>
prompt <li class="footnote">left click on a bar on the chart to filter data in table by snapshot</li>
prompt <li class="footnote">sql_id filters by prefix, enter "Snap total" as sql_id to filter records with snap aggregated values</li>
prompt <li class="footnote">Click on column header to sort data</li>
prompt </ul>
prompt <div id="div_top_sqls_filter" style='width:250px;padding-top:10px;padding-bottom:10px;float:left;'></div>
prompt <div id="div_top_sqls_snap_filter" style='width:250px;padding-top:10px;padding-bottom:10px;float:left'></div>
prompt <div id="reset_filters" style='width:250px;padding-top:10px;padding-bottom:10px;float:left'>
prompt 	<button style='width:150px;padding: 0px 5px;border-radius: 4px;' onclick="resetFilters();"> Clear filters</button>
prompt <script type="text/javascript">
prompt 		function resetFilters() {
prompt 		  snap_filter.setState({'value': null});
prompt 		  sqlid_filter.setState({'value': null});
prompt 		  snap_filter.draw();
prompt 		  sqlid_filter.draw();
prompt 		}
prompt     </script>
prompt </div>
prompt <div id="div_top_sqls_tab" class="tab100pct" style='height:150px;clear:left;'></div>
prompt </div>
prompt <a class="fnnav" href="#h_toc">back to top</a>

spool off
set termout on
prompt Gathering top SQL statements text...
set termout off
spool &&MAINREPORTFILE append

prompt <h2 id="h_sql_text"> List of SQL Text </h2>

set pagesize 40000
set markup html on head "" TABLE "class='sql' style='width:100%;'"
col sql_id entmap off
col sql_text entmap off
with snap as
(
  select /*+materialize*/ /*workaround for Bug 28749853*/ snap_id,dbid,instance_number
    ,cast(end_interval_time as date) as snap_time
    ,row_number() over (order by snap_id desc) rn
    ,to_char(cast(end_interval_time as date),'YYYY')||','||to_char(to_number(to_char(cast(end_interval_time as date),'MM'))-1)||','||to_char(cast(end_interval_time as date),'DD,HH24,MI') chart_dt
    ,round(((cast(end_interval_time as date)-nvl(lag(cast(end_interval_time as date)) over (partition by startup_time order by snap_id),cast(end_interval_time as date))))*24*60*60) ela_snap_sec
    ,startup_time
    ,case when nvl(lag(startup_time) over(order by startup_time),startup_time) <> startup_time then 1 else 0 end restart
  from dba_hist_snapshot
  where snap_id between :bsnap and :esnap
    and dbid = :dbid
    and instance_number = :inst_id
),
sqls as
(
  select snap_id,dbid,instance_number
    ,sql_id
    ,parsing_schema_name
    ,module
    ,plan_hash_value
    ,executions_delta execs
    ,buffer_gets_delta gets
    ,cpu_time_delta cpu
    ,elapsed_time_delta ela
    ,iowait_delta user_io
    ,apwait_delta appli
    ,ccwait_delta concurr
    ,plsexec_time_delta plsql
    ,rows_processed_delta rows_p
    ,ela_snap_sec
    ,chart_dt
  FROM dba_hist_sqlstat  join snap using(snap_id,dbid,instance_number)
),
sdiff2 as
(
select snap_id, dbid, instance_number,ela_snap_sec,chart_dt
  ,sql_id, plan_hash_value,module,parsing_schema_name as schema
  ,execs
  ,gets
  ,round(gets/decode(execs,0,1,execs),2) gets_exec
  ,round(cpu/1000000,2) cpu_sec
  ,round(cpu/decode(execs,0,1,execs)/1000000,4) cpu_sec_exec
  ,round(ela/1000000,2) ela_sec
  ,round(ela/decode(execs,0,1,execs)/1000000,4) ela_sec_exec
  ,row_number() over (partition by snap_id order by ela desc) top_n_ela
  ,row_number() over (partition by snap_id order by cpu desc) top_n_cpu
  --,row_number() over (order by snap_id,ela desc) rn
from sqls
where execs is not null
),sql_ids
as(
select
  distinct sql_id
from sdiff2 
where top_n_ela <= :nTopSqls or top_n_cpu <= :nTopSqls
)
select 
  '<div id="'||sql_id||'">'||sql_id||'</div>' sql_id
  --,dbms_lob.substr(sql_text,4000,1) sql_text
  ,'<pre>'||sql_text||'</pre>' as sql_text
from dba_hist_sqltext
where sql_id in (select sql_id from sql_ids)
order by sql_id;

set markup html off

prompt <a class="fnnav" href="#h_toc">back to top</a>
prompt 
prompt <hr>
prompt </body>
prompt </html>
prompt 

spool off

begin
  :etime := dbms_utility.get_time();
end;
/

col host_grep_cmd new_val host_grep_cmd noprint
select 
  case 
    when upper('&&_EDITOR') = 'NOTEPAD' then
      'findstr "^ORA- ^PLS- ^SP2-"'
    else
      'grep -E "^ORA-|^PLS-|^SP2-"'
  end host_grep_cmd
from dual;

set termout on
prompt ==================================================================
prompt Generated report: &&MAINREPORTFILE
prompt ==================================================================

col "Elapsed time" form A15
select cast(numtodsinterval((:etime-:stime)/100,'SECOND') as interval day(0) to second(0)) as "Elapsed time" from dual;

prompt ==================================================================
prompt  Checking for errors in generated report...
prompt  If anything is reported below, charts will not display properly...
prompt ==================================================================
host &&host_grep_cmd &&MAINREPORTFILE

exit;
