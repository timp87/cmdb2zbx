# What is it?
This script is used to sync hosts info from HP OpenView Service Desk CMDB to Zabbix.
It uses direct connection to CMDB's MSSQL DB and Zabbix API.

## Main idea
In our company we use HP OpenView Service Desk CMDB to store information about our hardware. It can be bare metall or virtual servers, cluster entities or roles, any kind of network devices or even UPSs.
In our company we use Zabbix as a monitoring system to watch them.
Let's syncronize some of the information from CMDB to Zabbix!

## Some Requirements
$ cat /usr/local/etc/freetds/freetds.conf
[global]
....
[cmdb_host]
        host = hostname.example.org
        port = 1433
        tds version = 8.0
        client charset = UTF-8
