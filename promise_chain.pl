#!/usr/bin/env perl

package main;

use Mojo::Base;
use Mojo::Promise;

# Experiment with implementing an asynchronous processing chain
#
# Previously, I implemented this using Mojo::EventEmitter:
#
# * All Sources, Filters and Sinks inherit from Mojo::EventEmitter
# * a Source is started, and it emits a firehose of read events
# * downstream elements subscribe to the upstream read events
# * they do some processing of data and emit their own firehose of
#   read events
# * the Sink only emits a close event (passed along the chain at eof)
#
# The entire chain is started by calling the start() method on the
# Source object.

#
# This script experiments with a different implementation using
# promises:
#
# * instead of data being pushed downstream from Source, it's pulled
#   from the Sink
# * downstream objects call read_p, which returns a promise
# * if we already have enough data to fulfil the promise, we resolve
#   it immediately
# * if we don't, we may have to request a promise from upstream
# 
# The entire chain is started by calling the start() method on the
# Sink object.

package StringSource;

use Mojo::Promise;
use Mojo::IOLoop;
use warnings;

sub new {
    bless { string => $_[1], eof => 0 }, $_[0]
}

# Return $bytes bytes from front of string to resolve/reject the
# promise
sub _do_chunk {
    my $self = shift;
    my $bytes = shift;
    if ($self->{eof}) {
	$self->{promise} -> reject("Attempted read past EOF");
    } else {
	# pass eof flag with data
	$bytes = substr($self->{string}, 0, $bytes, "");
	# warn "in Source::_do_chunk (sending: $bytes)\n";
	$self->{eof}++ if $self->{string} eq "";
	$self->{promise} -> resolve($bytes, $self->{eof});
    }
}

sub read_p {
    my $self = shift;
    my $bytes = shift // 4;

    # We don't block, so can we return a fulfilled promise?
    # Better to schedule it for later.
    Mojo::IOLoop->next_tick(sub { $self->_do_chunk($bytes) });
    $self->{promise} = Mojo::Promise->new;
}

1;

package ToUpper;

use warnings;

sub new {
    bless { upstream => $_[1], buf => "" }, $_[0]
}

sub read_p {
    my $self = shift;
    my $bytes = shift // 4;

    # We shouldn't need to do buffering because we never get more
    # bytes back from upstream than we requested.

    # New promise that we return
    my $promise = $self->{promise} = Mojo::Promise->new;

    # Chain into upstream promise
    $self->{upstream}->read_p($bytes)
	->then(
	sub {
	    my ($data, $eof) = @_;
	    # warn "in ToUpper::read_p (data: $data, eof: $eof)\n";
	    $data =~ y/a-z/A-Z/;
	    $promise->resolve($data, $eof);
	    $promise = undef;
	    #warn "got here\n";
	},
	sub {
	    $promise->reject($_[0]);
	    $promise = undef;
	});

    $promise;
}

1;

package StringSink;

# Rather than return a promise, we'll raise "finished"
# or "error" events.

use Mojo::Base 'Mojo::EventEmitter';
use warnings;

sub new {
    bless { upstream => $_[1], string => '', running => 0 }, $_[0]
}

sub string { $_[0] -> {string} }

sub _do_chunk {
    my $self = shift;
    return unless $self->{running};

    # We're not returning promises, but we do have to emit stuff
    $self->{upstream}->read_p()
	->then(
	sub {
	    my ($data, $eof) = @_;
	    # warn "in Sink::_do_chunk (data: $data, eof: $eof)\n";
	    $self->{string} .= $data;
	    if ($eof) {
		$self->emit(finished => $self->{string});
	    } else {
		# if not at eof, queue up next chunk of work
		Mojo::IOLoop->next_tick(sub { $self->_do_chunk });
	    }
	},
	sub {
	    $self->emit(error => $_[1])
	});

}

sub stop { $_[0]->{running} = 0 }
sub start {
    my $self = shift;
    return if $self->{running}++;
    Mojo::IOLoop->next_tick(sub { $self->_do_chunk } );
}

1;

package main;

use Mojo::IOLoop;

# Build the chain
my $source = StringSource->new("This was a string with CamelCase\n");
my $filter = ToUpper->new($source);
my $sink   = StringSink->new($filter);

# Start events
$sink->on(finished => sub { warn "'finished' event: string is $_[1]\n" });
$sink->start;
Mojo::IOLoop->start;

# Alternative way to report (no promises or next_ticks outstanding)

print $sink->string();
