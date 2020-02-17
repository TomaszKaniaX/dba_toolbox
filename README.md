# dba_toolbox
Scripts for Statspack/AWR snapshot trend analysis.
Use GoogleChart API, inspired by https://carlos-sierra.net/2014/07/28/free-script-to-generate-a-line-chart-on-html/
1) sp_trends_charts.sql - Graphical statspack report - run as perfstat and enter report criteria
2) awr_trends_charts.sql - same as above but based on AWR

Loading more than a week of data into report may cause slownes when displaying charts.
Works terribly slow in Internet Explorer - use internet browser instead.