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
    my $routing_key = RT->Config->Get('PagerDutyRoutingKey');

    my $endpoint = "https://events.pagerduty.com/v2/enqueue";

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

    my $payload = {
        routing_key  => $routing_key,
        event_action => 'trigger',
        dedup_key    => '' . $self->TicketObj->id,
        payload => {
            summary  => $self->TicketObj->Subject,
            source   => $queue_service  || 'RT',
            severity => $queue_priority || 'critical',
        },
        links => [
            {
                href => RT->Config->Get('WebBaseURL') . '/' . $ticket->id,
                text => 'RT Ticket',
            },
        ],
    };


    my $payload_json = JSON::encode_json($payload); 

    my $ua = LWP::UserAgent->new(); 
    $ua->timeout(10); 

    $RT::Logger->info('Creating incident on PagerDuty');
    my $post_response = $ua->post($endpoint,
        'Accept'        => 'application/vnd.pagerduty+json;version=2',
        'Content-Type'  => 'application/json',
        'Content'       => $payload_json,
    );

    if ($post_response->is_success) { 
        # Add reference to CF
        my $response = JSON::decode_json($post_response->decoded_content);

        $ticket->Comment(
             Content => 'Response from PagerDuty: ' . $response->{'message'} . "\nstatus: " . $response->{'status'},
        );
    } else { 
        $RT::Logger->error('Failed to create incident on PagerDuty (',
            $post_response->code ,': ', $post_response->message, ', json: ', $post_response->decoded_content, ')');

        $ticket->Comment(
             Content => 'Failed to create incident in PagerDuty: ' . $post_response->message . "\n" . $post_response->decoded_content
        );
    }

    return 1;
}
