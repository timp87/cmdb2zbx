#!/usr/local/bin/perl

use strict;
use warnings;

use JSON::RPC::Legacy::Client;
use DBI;
use Data::Dumper;

# ZBX options
#my $zbx_url = 'https://monitoring.example.org/api_jsonrpc.php';
my $zbx_url = 'http://proxy.examplelab.org/api_jsonrpc.php';
my $zbx_authid;
my $zbx_result;
#my $zbx_sync_groupid = 89;  # ZBX host group, the members of which we synchronize
my $zbx_sync_groupid = 8;
my $zbx_user = 'sync_info';
my $zbx_pass = 'l00ksl!ke';
my ($sec, $min, $hour, $day) = localtime;
my $zbx_reqid = '0' . $day . $hour . $min . $sec;

# CMDB options
my $cmdb_host = 'sdeskdb';
my $cmdb_user = 'reader';
my $cmdb_pass = 'xbnfntkm';

# The main hash for hosts information
my %hosts;

# Debug options
my $debug = 0;
my $debug_dumper = 1;

my $ca_cert = '/etc/ssl/certs/exampleca.pem';

binmode STDOUT, ':encoding(UTF-8)';
#use open qw/ :std :encoding(UTF-8) /;



# Let's go!


# Create a client for ZBX
my $zbx_client = JSON::RPC::Legacy::Client->new;
#$zbx_client->ua->ssl_opts(verify_hostname => 1);
#$zbx_client->ua->ssl_opts(SSL_ca_file => $ca_cert);


# Try to authenticate to ZBX
$zbx_authid = &zbx_call( 'user.login',
    {   user => $zbx_user,
        password => $zbx_pass,
    },
);
print "Authentication successful. Auth ID: " . $zbx_authid . "\n" if $debug;


# Get list of hosts from ZBX
$zbx_result = &zbx_call( 'host.get',
    {   groupids => $zbx_sync_groupid,
        output => ['hostid', 'name',],
    },
);


# Fill the hosts hash with initial info
foreach my $line (@$zbx_result) {
    my $hostid = $line->{'hostid'};
    my $hostname = $line->{'name'};
    $hosts{$hostid} = {'hostname' => $hostname,};
}
print Dumper(\%hosts) if $debug_dumper;
print "________________________\n" if $debug_dumper;


# Try to make a connection and authenticate to CMDB
my $dbh = DBI->connect("dbi:Sybase:$cmdb_host", $cmdb_user, $cmdb_pass,
    {   PrintError => 0,        # Don't report errors via warn()
        RaiseError => 1,        # Do report errors via die()
        AutoCommit => 1,
    },
);


# A way to set LongReadLen correctly
$dbh->do("set textsize 32000");


# Fill the hosts hash with main info
foreach my $hostid (keys %hosts) {
    my $hostname = $hosts{$hostid}->{'hostname'};

    # Get info about hosts from CMDB
    my $sql = "SELECT CIT_NAME2 AS software_full, CIT_REMARK AS notes, ITSM_LOCATIONS.LOC_SEARCHCODE AS location, ITSM_PERSONS.PER_EMAIL AS email, ITSM_PERSONS.PER_REMARK AS contact
        FROM ITSM_CONFIGURATION_ITEMS
                LEFT JOIN ITSM_LOCATIONS ON ITSM_CONFIGURATION_ITEMS.CIT_LOC_OID=ITSM_LOCATIONS.LOC_OID
                LEFT JOIN ITSM_PERSONS ON ITSM_CONFIGURATION_ITEMS.CIT_ADMIN_PER_OID=ITSM_PERSONS.PER_OID
                    WHERE CIT_NAME1='$hostname';";

    my $sth = $dbh->prepare($sql);
    $sth->execute;

    while (my $row = $sth->fetchrow_hashref) {
        while (my ($field, $value) = each %$row) {
            if (defined $value) {
                utf8::decode($value);
                $hosts{$hostid}->{$field} = $value;
            }
        }
    }
}
print Dumper(\%hosts) if $debug_dumper;
print "________________________\n" if $debug_dumper;


# Fill the hosts hash with admins info
foreach my $hostid (keys %hosts) {
    my $hostname = $hosts{$hostid}->{'hostname'};

    my $sql = "SELECT PER_REMARK AS contact FROM ITSM_PERSONS WHERE PER_OID IN
        (SELECT CIU_USER_PER_OID FROM ITSM_CI_USERS WHERE CIU_CIT_OID IN
            (SELECT CIT_OID FROM ITSM_CONFIGURATION_ITEMS WHERE CIT_NAME1='$hostname'));";

    my $sth = $dbh->prepare($sql);
    $sth->execute;

    while (my $row = $sth->fetchrow_hashref) {
        while (my ($field, $value) = each %$row) {
            if (defined $value) {
                utf8::decode($value);
                $hosts{$hostid}->{$field} = join ', ', $hosts{$hostid}->{$field}, $value;
            }
        }
    }
}
print Dumper(\%hosts) if $debug_dumper;
print "________________________\n" if $debug_dumper;


# Disconnect from CMDB
$dbh->disconnect;



# Lets sync
foreach my $hostid (keys %hosts) {
    my %inventory;
    while (my ($field, $value) = each %{$hosts{$hostid}}) {
        next if ($field eq 'hostname' or $field eq 'email');
        $inventory{$field} = $value;
    }
    $zbx_result = &zbx_call( 'host.update',
        {   hostid => $hostid,
            inventory_mode => 0,
            inventory => \%inventory,
        },
    );
}






sub zbx_call {
    my ($method, $params) = @_;

    my $json = {
        jsonrpc => "2.0",
        id => $zbx_reqid++,
        auth => $zbx_authid,
        method => $method,
        params => $params,
    };

    my $response = $zbx_client->call($zbx_url, $json);
    print Dumper($response->content) if $debug_dumper;

    die "ZBX: The response from server is empty! Status code is '", $zbx_client->status_line, "'.\n" unless $response; 
    die "ZBX: Method '$method' failed. ", $response->error_message->{'data'}, "\n" if $response->is_error;

    $response->result;
}
