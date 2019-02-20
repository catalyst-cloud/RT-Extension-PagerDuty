use strict;
use warnings;
use LWP::UserAgent;
use JSON;

package RT::Action::NotifyPagerDuty;
use base qw(RT::Action);

our $VERSION = '0.01';

# To install, run:
#    rt-setup-database --action insert --datafile db/initialdata

# Create for example a scrip with:
#   Description: Create PagerDuty Incident
#   Condition:   On Create
#   Action:      Notify PagerDuty
#   Template:    Blank
#   Stage:       Normal
#   Enabled:     Yes
#
# Then assign that scrip to the queues which you want to notify PagerDuty.
# If you create a CustomField called 'Incident Priority' for the queue, then
# you can set the priority that is assigned in PagerDuty.
#
# Create a Queue CustomField called 'PD Incident Service ID', which ID for PD service.

sub Prepare {
    my $shelf = shift;

    return 1;
};

sub Commit {
    my $self = shift;

    my $api_token = RT->Config->Get('PagerDutyAPIToken');

    my $endpoint = "https://api.pagerduty.com/incidents";

    my $payload = {
        incident => {
            from         => RT->Config->Get('PagerDutyFrom'),
            title        => $self->TicketObj->Subject,
            incident_key => '' . $self->TicketObj->id,
        },
    };

    my $ticket = $self->TicketObj;
    my $queue  = $ticket->QueueObj;

    my $queue_priority_cf_name = RT->Config->Get('PagerDutyQueueCFPriority') || 'Incident Priority ID';
    my $queue_priority = $queue->FirstCustomFieldValue($queue_priority_cf_name);

    if ($queue_priority) {
        $payload->{'incident'}{'priority'} = {
            id   => $queue_priority,
            type => 'priority_reference',
        };
    }

    my $queue_service_cf_name = RT->Config->Get('PagerDutyQueueCFService') || 'Incident Service ID';
    my $queue_service = $queue->FirstCustomFieldValue($queue_service_cf_name);

    $payload->{'incident'}{'service'} = {
        id   => $queue_service,
        type => 'service_reference',
    };

    my $payload_json = JSON::encode_json($payload); 

    my $ua = LWP::UserAgent->new(); 
    $ua->timeout(10); 

    $RT::Logger->info('Creating incident on PagerDuty');
    my $post_response = $ua->post($endpoint,
        'Authorization' => 'Token token=' . $api_token,
        'Accept'        => 'application/vnd.pagerduty+json;version=2',
        'Content-Type'  => 'application/json',
        'Content'       => $payload_json,
    );

    if ($post_response->is_success) { 
        # Add reference to CF
        my $response = JSON::decode_json($post_response->decoded_content);

        my $pd_html_cf = $self->TicketObj->CustomField('PagerDuty HTML');
        if ($pd_html_cf) {
            $self->Ticket->AddCustomFieldValue(
                Field => $pd_html_cf,
                Value => $response->{'incident'}{'html_url'},
            );
        }

        $self->TicketObj->Comment(
             Content => 'Allocated in PagerDuty to ' . $response->{'incident'}{'assignee'}{'summary'},
        );
    } else { 
        $RT::Logger->error('Failed to create incident on PagerDuty ('. 
            $post_response->code .': '. $post_response->message .')'); 

        $self->TicketObj->Comment(
             Content => 'Failed to create incident in PagerDuty: ' . $post_response->message . "\n" . $post_response->decoded_content,
        );
    }

    return 1;
}
