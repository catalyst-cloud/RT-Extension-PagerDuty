use strict;
use warnings;
use LWP::UserAgent;
use JSON;

package RT::Action::NotifyPagerDuty;
use base qw(RT::Action);

our $VERSION = '0.02';

=head1 NAME

RT-Action-NotifyPagerDuty - Create or update an incident in PagerDuty

=head1 DESCRIPTION

This action allows you to create or update incidents in PagerDuty
when a ticket is created or updated in Request Tracker.

=head1 RT VERSION

Works with RT 4.4.x, not tested with 4.6.x yet.

=head1 INSTALLATION

=over

=item C<perl Makefile.PL>

=item C<make>

=item C<make install>

May need root permissions

=item C<rt-setup-database --action insert --datafile db/initialdata>

May need root permissions

=item Edit your F</opt/rt4/etc/RT_SiteConfig.pm>

Add this line:

    Plugin('RT::Action::NotifyPagerDuty');

In PagerDuty.com add a new service, selection "Use our API directly" and
select "Events API v2" and whatever other settings you need. Take the routing
key they generate and add a line like this:

    Set ($PagerDutyRoutingKey, 'key_goes_here');

Other settings you may want to add, with their defaults:

    Set ($PagerDutyQueueCFService, 'Incident Service');

=item Restart your webserver

=item In RT, you need to create a new Scrip

Create for example a scrip with:

    Description: Create or Update PagerDuty Incident
    Condition:   On Transaction
    Action:      Notify PagerDuty
    Template:    Blank
    Stage:       Normal
    Enabled:     Yes

Then assign that scrip to the queues which you want to notify PagerDuty.

=back

=head1 CONFIGURATION

There are only a few settings that can be configured.

Currently you can set the PagerDuty priority and services to be used
via Queue CustomFields.

=over

=item Priority

The PagerDuty incident priority which this incident will be created using.

By default the Queue CustomField is named "Incident Priority", but you can
change that with:

    Set ($PagerDutyQueueCFPriority, 'Incident Priority');

The allowed values are: critical, warning, error, or info.

If no priority is set, or an invalid value is used, critical will be used.

=item Service

The PagerDuty service which this incident will be created using.

By default the Queue CustomField is named "Incident Service", but you can
change that with:

    Set ($PagerDutyQueueCFService, 'Incident Service');

If no service is defined, then RT is used.

=back

=head1 AUTHOR

Andrew Ruthven, Catalyst Cloud Ltd E<lt>puck@catalystcloud.nz<gt>

=for html <p>All bugs should be reported via email to <a
href="mailto:bug-RT-Action-NotifyPagerDuty@rt.cpan.org">bug-RT-Action-NotifyPagerDuty@rt.cpan.org</a>
or via the web at <a
href="http://rt.cpan.org/Public/Dist/Display.html?Name=RT-Action-NotifyPagerDuty">rt.cpan.org</a>.</p>

=for text
    All bugs should be reported via email to
        bug-RT-Action-NotifyPagerDuty@rt.cpan.org
    or via the web at
        http://rt.cpan.org/Public/Dist/Display.html?Name=RT-Action-NotifyPagerDuty

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2019 by Catalyst Cloud Ltd

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

# As we use a custom RT::Transaction, we need to add our _BriefDescription.
{
    package RT::Transaction;
    our %_BriefDescriptions;

    $_BriefDescriptions{"PagerDuty"} = sub {
        return ("Incident [_1] in PagerDuty", $_[0]->NewValue);  #loc();
    };
}

sub Prepare {
    my $shelf = shift;

    return 1;
};

sub Commit {
    my $self = shift;

    # If the status is:
    #  - new, trigger an incident;
    #  - resolved, rejected or deleted, , resolve an incident;
    # If the owner is set, acknowledge the incident.
    my ($pd_action, $pretty_action);
    my $txnObj = $self->TransactionObj;

    if ($txnObj->Type eq 'Create') {
        $pd_action     = 'trigger';
        $pretty_action = 'triggered';

    } elsif ($txnObj->Type eq 'Status'
             && $txnObj->OldValue !~ /^resolved|rejected|deleted$/
             && $txnObj->NewValue =~ /^resolved|rejected|deleted$/
            ) {
        $pd_action     = 'resolve';
        $pretty_action = 'resolved';

    } elsif ($txnObj->Type eq 'Set'
             && $txnObj->Field eq 'Owner'
             && $txnObj->NewValue != $RT::SystemUser->id
            ) {
        $pd_action     = 'acknowledge';
        $pretty_action = 'acknowledged';
    }

    # If $pd_action isn't set, then we have nothing to do.
    return 1 unless defined $pd_action;

    my $ticket = $self->TicketObj;
    my $queue  = $ticket->QueueObj;

    my $queue_priority_cf_name = RT->Config->Get('PagerDutyQueueCFPriority') || 'Incident Priority';
    my $queue_priority = $queue->FirstCustomFieldValue($queue_priority_cf_name);

    # Set the priority to what PagerDuty supports.
    if ($queue_priority) {
        $queue_priority = lc($queue_priority);
        if ($queue_priority !~ /^critical|warning|error|info$/) {
            $RT::Logger->error("Pager Duty priority is $queue_priority, which isn't supported by PD, changing to critical");
            $queue_priority = 'critical';
        }
    }

    my $queue_service_cf_name = RT->Config->Get('PagerDutyQueueCFService') || 'Incident Service';
    my $queue_service = $queue->FirstCustomFieldValue($queue_service_cf_name);

    my $txn_content = $self->_PDEnqueue(
        queue_service => $queue_service,
        pd_action     => $pd_action,
    );

    return unless defined $txn_content;

    # We need to give RT::Record::_NewTransaction a MIME object to have it
    # store our content for us.
    my $MIMEObj = MIME::Entity->build(
        Type    => "text/plain",
        Charset => "UTF-8",
        Data    => [ Encode::encode("UTF-8", $txn_content) ],
    );

    $self->TicketObj->_NewTransaction(
        Type     => 'PagerDuty',
        NewValue => $pretty_action,
        MIMEObj  => $MIMEObj,
    );

    return 1;
}

# Use the Events v2 API: https://v2.developer.pagerduty.com/docs/events-api-v2
sub _PDEnqueue {
    my $self = shift;
    my %args = (
        queue_service  => undef,
        queue_priority => undef,
        pd_action      => 'trigger',
        @_
    );

    my $routing_key = RT->Config->Get('PagerDutyRoutingKey');

    my $payload = {
        routing_key  => $routing_key,
        event_action => $args{pd_action},
        dedup_key    => 'rt#' . $self->TicketObj->id,
        payload => {
            summary  => $self->TicketObj->Subject,
            source   => $args{queue_service}  || 'RT',
            severity => $args{queue_priority} || 'critical',
            class    => 'Ticket',
        },
        links => [
            {
                href => RT->Config->Get('WebBaseURL') . '/' . $self->TicketObj->id,
                text => 'RT Ticket',
            },
        ],
    };

    my $payload_json = JSON::encode_json($payload);

    my $ua = LWP::UserAgent->new();
    $ua->timeout(10);

    $RT::Logger->info('Queuing incident on PagerDuty');

    my $endpoint = "https://events.pagerduty.com/v2/enqueue";
    my $post_response = $ua->post($endpoint,
        'Accept'        => 'application/vnd.pagerduty+json;version=2',
        'Content-Type'  => 'application/json',
        'Content'       => $payload_json,
    );

    my $txn_content;
    if ($post_response->is_success) {
        my $response = JSON::decode_json($post_response->decoded_content);

        $txn_content = 'Response from PagerDuty: ' . $response->{'message'} . "\nStatus from PagerDuty: " . $response->{'status'};
    } else {
        $RT::Logger->error('Failed to create incident on PagerDuty (',
            $post_response->code ,': ', $post_response->message, ', json: ', $post_response->decoded_content, ')');

        $txn_content = 'Failed to create incident in PagerDuty: ' . $post_response->message . "\n" . $post_response->decoded_content;

        if ($post_response->code != 400) {
            # Queue the request up for a retransmit.
        }
    }

    return $txn_content;
}

# Use the Incident API: https://api-reference.pagerduty.com/#!/Incidents/get_incidents
sub _PDCreationAPI {
    my $self = shift;
    my %args = (
        queue          => undef,
        queue_service  => undef,
        queue_priority => undef,
        @_
    );

    my $queue_from_cf_name = RT->Config->Get('PagerDutyQueueCFFrom') || 'Incident From';
    my $queue_from = $args{queue}->FirstCustomFieldValue($queue_from_cf_name);

    if (! defined $queue_from) {
        # Try looking for a global config.
        $queue_from = RT->Config->Get('PagerDutyFrom');
    }

    if (! defined $queue_from) {
        $RT::Logger->error('Failed to create incident on PagerDuty (No From account set in config or queue)');
        return undef;
    }

    my $payload = {
        incident => {
            type    => 'incident',
            title   => $self->TicketObj->Subject,
            from    => $queue_from,
            service => {
                id   => $args{queue_service},
                type => 'service_reference',
            },
            incident_key => 'rt#' . $self->TicketObj->id,
            body    => {
                type    => 'incident_body',
                details => RT->Config->Get('WebBaseURL') . '/' . $self->TicketObj->id,
            },
        },
    };

    if (defined $args{queue_priority}) {
        $payload->{'priority'} = {
            id => $args{queue_priority},
            type => "priority_reference",
        };
    }

# How do you add a link via this API?
#        links => [
#            {
#                href => RT->Config->Get('WebBaseURL') . '/' . $self->TicketObj->id,
#                text => 'RT Ticket',
#            },
#        ],

    my $payload_json = JSON::encode_json($payload);

    my $ua = LWP::UserAgent->new();
    $ua->timeout(10);

    $RT::Logger->info('Creating incident on PagerDuty');

    my $api_token = RT->Config->Get('PagerDutyAPIToken');

    my $endpoint = "https://api.pagerduty.com/incidents";
    my $post_response = $ua->post($endpoint,
        'Accept'        => 'application/vnd.pagerduty+json;version=2',
        'Authorization' => "Token token=$api_token",
        'Content-Type'  => 'application/json',
        'Content'       => $payload_json,
    );

    my $txn_content;
    if ($post_response->is_success) {
        my $response = JSON::decode_json($post_response->decoded_content);

        $txn_content = join("\n",
          'Status from PagerDuty: ' . $response->{'status'},
          'PagerDuty link: ' . $response->{'html_url'},
          'Assigned in PagerDuty to: ' . $response->{'assignments'}{'assignee'}{'summary'}
        );

        my $ticket_pd_id_cf_name = RT->Config->Get('PagerDutyTicketCFID') || 'Incident Id';
        my ($cf_status, $cf_msg) = $self->TicketObj->AddCustomFieldValue(
            Field => $ticket_pd_id_cf_name,
            Value => $response->{'id'},
            RecordTransaction => 0,
        );
        if ($cf_status == 0) {
            $txn_content .= "\nFailed to set CF for PagerDuty Id: $cf_msg";
        }

        my $ticket_pd_link_cf_name = RT->Config->Get('PagerDutyTicketCFLink') || 'Incident Link';
        ($cf_status, $cf_msg) = $self->TicketObj->AddCustomFieldValue(
            Field => $ticket_pd_link_cf_name,
            Value => $response->{'html_ref'},
            RecordTransaction => 0,
        );
        if ($cf_status == 0) {
            $txn_content .= "\nFailed to set CF for PagerDuty Link: $cf_msg";
        }
    } else {
        $RT::Logger->error('Failed to create incident on PagerDuty (',
            $post_response->code ,': ', $post_response->message, ', json: ', $post_response->decoded_content, ')');

        $txn_content = 'Failed to create incident in PagerDuty: ' . $post_response->message . "\n" . $post_response->decoded_content;

        # TODO: Cache to disk for later attempt.
    }


    return $txn_content;
}

1;
