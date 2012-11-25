#!/usr/bin/perl

package LCABot;

use Modern::Perl '2012';
use Data::Dump;

use LWP::Simple;
use JSON::XS qw( decode_json );
use POE qw( Wheel::Run );

use DateTime;
use List::Util qw( first );

use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::BotCommand;

sub new {
	my $class = shift;
	my $this = bless {
		debug => [],
		@_
	}, $class;

	# Create a custom POE Session for non-IRC events
	POE::Session->create(
		object_states => [
			$this => {
				_start   => 'nonirc_start',
				tweet    => 'tweet_state',
				schedule => 'schedule_state',
			}
		]
	);

	return bless $this;
}

sub run {
	my $this = shift;

	POE::Session->create(
		object_states => [
			$this => [qw(_start irc_botcmd_debug irc_botcmd_nodebug irc_botcmd_next irc_botcmd_testtime irc_botcmd_time irc_botcmd_help)],
		]
	);


	$poe_kernel->run();
}

sub _start {
	my ($this, $kernel) = @_[OBJECT, KERNEL];

	$kernel->alias_set("irc_alias"); # Prevent garbage collection
	my $irc = POE::Component::IRC::State->spawn(debug => 1, Flood => 1);
	$irc->plugin_add('Connector' => POE::Component::IRC::Plugin::Connector->new());
	$irc->plugin_add('AutoJoin' => POE::Component::IRC::Plugin::AutoJoin->new( Channels => $this->{channels} ));
	$irc->plugin_add('BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
		Commands => {
			help     => 'List help',
			debug    => 'Causes the bot to send you debug information.',
			nodebug  => 'Stops the bot sending you debug information.',
			testtime => 'Set the current time of the bot for testing purposes.',
			next     => 'Display the next group of events.',
			time     => 'Current time.',
		},
		In_channels  => 0,  # Ignore in-channel commands
		Bare_private => 1,  # No need for a prefix when talking to us
		Prefix => '',
		Ignore_unknown => 1,
	));
	$irc->yield(register => qw(join));
	$irc->yield(register => 'all');
	$irc->yield(connect => {
		Nick     => $this->{nick},
		Server   => $this->{server},
		Port     => $this->{port},
		Password => $this->{password},
		Ircname  => $this->{name},
	} );
	
	$this->{irc} = $irc;
	return;
}

sub irc_botcmd_help {
	my ($this, $user, $channel) = @_[OBJECT, ARG0, ARG1];
	my $nick = (split /!/, $user)[0];

	my $debug_cmds = $main::PRODUCTION ? "" :
		"    debug - send debug monitoring messages.\n".
		"    nodebug - stop sending debug messages.\n".
		"    testtime - set the time that the bot thinks it is.\n".
		"        Format: YYYY-MM-DD HH:MM.\n".
		"        A time of 0 or \"reset\" will reset back to real time.\n";
	my $reply =
		"This bot announces upcoming events and snippits from twitter.\n \n".
		"Commands:\n".
		"    next - Communicate the next event.\n".
		"    time - The current time.\n".
		$debug_cmds.
		"All commands must be sent as a private message.\n".
		"The bot will always respond in kind.";

	$this->{irc}->yield('notice', $nick, $_) foreach (split(/\n/, $reply));
}

sub irc_botcmd_debug {
	my ($this, $user, $channel) = @_[OBJECT, ARG0, ARG1];
	my $nick = (split /!/, $user)[0];

	my $reply;
	if (grep {$_ eq $nick} @{$this->{debug}}) {
		$reply = "Already debug monitoring";
	} else {
		push $this->{debug}, $nick;
		$reply = "Added to debug monitoring";
	}
	$this->{irc}->yield('notice', $nick, $reply);
}

sub irc_botcmd_nodebug {
	my ($this, $user, $channel) = @_[OBJECT, ARG0, ARG1];
	my $nick = (split /!/, $user)[0];

	dd($this->{debug});
	$this->{debug} = (grep {$_ ne $nick} @{$this->{debug}}) || [];
	$this->{irc}->yield('notice', $nick, "Removed from debug monitoring");
}

sub irc_botcmd_testtime {
	my ($this, $user, $channel) = @_[OBJECT, ARG0, ARG1];
	my $nick = (split /!/, $user)[0];
	my $cmd_params = $_[ARG2];

	break if $main::PRODUCTION; # Testing only

	my $reply;
	if ($cmd_params =~ /(\d{4}) -? (\d{2}) -? (\d{2}) [\sT] (\d{1,2}) :? (\d{2}) :? (\d{2})?/ix) {
		# Date & time provided
		my $new_time = DateTime->new(
			year => $1, month => $2, day => $3,
			hour => $4, minute => $5, second => $6 // 0,
			time_zone => 'Australia/Sydney',
		);
		$this->{time_offset_s} = $new_time->subtract_datetime_absolute(DateTime->now(time_zone => 'Australia/Sydney'))->seconds;
		$reply = "Offset set";
	} elsif (/^\D* 0 \D*$/x || /reset/) {
		$this->{time_offset_s} = 0;
		$reply = "Offset removed";
	} else {
		$reply = "Bad time format: testtime YYYY-MM-DD HH:MM";
	}
	$this->{irc}->yield('notice', $nick, $reply);
}

sub irc_botcmd_next {
	my ($this, $user, $channel) = @_[OBJECT, ARG0, ARG1];
	my $nick = (split /!/, $user)[0];

	my $now = time;
	$now += $this->{time_offset_s} if defined $this->{time_offset_s};
	my $next = first { $_ > $now } sort keys($main::schedule);
	last unless defined $next;

	foreach("Coming up at ".$main::schedule->{$next}[0]{Start}, map {$_->{prettyprint}} @{$main::schedule->{$next}}) {
		$this->{irc}->yield('notice', $nick, $_);
	}
}

sub irc_botcmd_time {
	my ($this, $user, $channel) = @_[OBJECT, ARG0, ARG1];
	my $nick = (split /!/, $user)[0];

	my $now = time;
	$now += $this->{time_offset_s} if defined $this->{time_offset_s};
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($now);

	$this->{irc}->yield('notice', $nick, sprintf("%d: %d-%02d-%02d %02d:%02d", $now, $year+1900, $mon+1, $mday, $hour, $min));
}

sub nonirc_start {
	my ($this, $kernel, $session) = @_[OBJECT, KERNEL, SESSION];

	$this->{last_sched} = time;

	$kernel->alias_set("non_irc"); # Prevent garbage collection
	$kernel->delay('tweet', 60); # Start tweeting in a minute
	$kernel->delay('schedule', 30); # Start schedule output in half a minute
}

sub tweet_state {
	my ($this, $kernel) = @_[OBJECT, KERNEL];

	my $tweets = $main::tweets;
	if ($tweets->pending) {
		my $twit = $tweets->dequeue;
		$this->{irc}->yield('notice', $_, $twit) foreach (keys %{$this->{channels}});
	}

	$kernel->delay('tweet', 60*5); # Tweet every five minutes
}

sub schedule_state {
	my ($this, $kernel) = @_[OBJECT, KERNEL];

	# Run the schedule command every minute, output any upcoming events
	# We record the time run because we can't guarantee that we
	# will run every minute, so it could be a few minutes late but we don't
	# want to retransmit.

	my $now = time;
	$now += $this->{time_offset_s} if defined $this->{time_offset_s};
	my $five_min = $now+(5*60); # Five minutes into the future, time of events we care about

	foreach (sort keys($main::schedule)) {
		next if $_ < $now; # Event is in the past, don't care
		next if $_ <= $this->{last_sched}; # Event has been sent already, don't care
		last if $_ > $five_min; # Event is further than five minutes away, don't care

		# At this point we have an event marker that occurs in the next five minutes

		# TODO: Multi-channel support
		foreach my $line ("Coming up at ".$main::schedule->{$_}[0]{Start}, map {$_->{prettyprint}} @{$main::schedule->{$_}}) {
			$this->{irc}->yield('notice', $_, $line) foreach (keys %{$this->{channels}});
		}

		$this->{last_sched} = $_;
	}
	
	$kernel->delay('schedule', 60); # Run every minute
}

1;


package main;

use Modern::Perl;
use Data::Dump;

use threads;
use threads::shared;
use Thread::Queue;

use DateTime;
use DateTime::Format::Strptime;

use LWP::Simple qw( get );
use JSON::XS qw( decode_json );

use List::Util qw( first );

our $PRODUCTION = 0; # Testing version has some bonus features

# Asynchronously update the schedule
#
# Format delivered by the server is an array of hashes, a hash for each entry.
# Hash fields are:
# 	Description => "Empty, or some rather long multiline text.",
# 	Duration    => "1:00:00",
# 	Event       => 21,
# 	Id          => 8,
# 	Room Name   => "Llewellyn Hall",
# 	Start       => "2013-01-28 09:00:00",
# 	Title       => "Keynote",
#
# We need to optimize for lookup by time.
# Sort to a hash with the start time (epoch seconds) as the key and an array of entries as the data.
# We also preformat a pretty print string, otherwise the hash fields are unchanged;
share($main::schedule);
threads->create( sub {
	my $time_parser = DateTime::Format::Strptime->new(
		pattern   => '%F %T',
		locale    => 'en_AU',
		time_zone => 'Australia/Sydney',
	);

	# TODO: Bad stuff if we don't have a net connection
	while (1) {
		my $delivered = decode_json(get("https://lca2013.linux.org.au/programme/schedule/json"));
		my %lookup;
		foreach (@$delivered) {
			$_->{prettyprint} = "$_->{Title} in $_->{'Room Name'}";
			my $ts = $time_parser->parse_datetime($_->{Start})->epoch;
			$lookup{$ts} = [] unless exists $lookup{$ts};
			push $lookup{$ts}, $_;
		}
		$main::schedule = shared_clone(\%lookup);
		sleep(3600); # Seconds, 1 hour
	};
})->detach();

# Asynchronously check twitter
our $tweets = Thread::Queue->new();
if (0) {
threads->create( sub {
	my $last_id = "&count=5"; # Blatant variable misuse, prime the pump with the last five historic entries
	while (1) {
		my $new_tweets = decode_json(get("https://search.twitter.com/search.json?q=%23lca2013&result_type=recent&since_id=$last_id"));

		# Tweets are ordered, most recent is first
		$tweets->enqueue(reverse map { "\@$_->{from_user} tweeted $_->{text}" } @{$new_tweets->{results}});

		# Clean out the queue so it doesn't get stale
		$tweets->dequeue while ($tweets->pending > 5);

		$last_id = $new_tweets->{results}[0]{id} if $new_tweets->{results}[0];

		sleep(180); # Seconds, 3 minutes
	};
})->detach();
}



my $bot = LCABot->new(

	server => "irc.freenode.org",
	password => "SECRET", # NickServ password
	channels => {"#lcainfo" => '', "#canberra2013" => "SECRET"},

	nick      => "lcainfo",
	name      => "LCA 2013 Information Bot",

);
$bot->run();
#while(1) {}; # Debugging

1;
