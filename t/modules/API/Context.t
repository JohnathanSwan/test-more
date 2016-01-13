use strict;
use warnings;

BEGIN { require "t/tools.pl" };

use Test2::API qw{
    context intercept
    test2_stack
    test2_add_callback_context_init
    test2_add_callback_context_release
};

my $error = exception { context(); 1 };
my $exception = "context() called, but return value is ignored at " . __FILE__ . ' line ' . (__LINE__ - 1);
like($error, qr/^\Q$exception\E/, "Got the exception" );

my $ref;
my $frame;
sub wrap(&) {
    my $ctx = context();
    my ($pkg, $file, $line, $sub) = caller(0);
    $frame = [$pkg, $file, $line, $sub];

    $_[0]->($ctx);

    $ref = "$ctx";

    $ctx->release;
}

wrap {
    my $ctx = shift;
    ok($ctx->hub, "got hub");
    delete $ctx->trace->frame->[4];
    is_deeply($ctx->trace->frame, $frame, "Found place to report errors");
};

wrap {
    my $ctx = shift;
    ok("$ctx" ne "$ref", "Got a new context");
    my $new = context();
    ok($ctx == $new, "Additional call to context gets same instance");
    delete $ctx->trace->frame->[4];
    is_deeply($ctx->trace->frame, $frame, "Found place to report errors");
    $new->release;
};

wrap {
    my $ctx = shift;
    my $snap = $ctx->snapshot;

    is_deeply($snap, {%$ctx, _canon_count => undef}, "snapshot is identical");
    ok($ctx != $snap, "snapshot is a new instance");
};

my $end_ctx;
{ # Simulate an END block...
    local *END = sub { local *__ANON__ = 'END'; context() };
    my $ctx = END(); $frame = [ __PACKAGE__, __FILE__, __LINE__, 'main::END' ];
    $end_ctx = $ctx->snapshot;
    $ctx->release;
}
delete $end_ctx->trace->frame->[4];
is_deeply( $end_ctx->trace->frame, $frame, 'context is ok in an end block');

# Test event generation
{
    package My::Formatter;

    sub write {
        my $self = shift;
        my ($e) = @_;
        push @$self => $e;
    }
}
my $events = bless [], 'My::Formatter';
my $hub = Test2::Hub->new(
    formatter => $events,
);
my $trace = Test2::Util::Trace->new(
    frame => [ 'Foo::Bar', 'foo_bar.t', 42, 'Foo::Bar::baz' ],
);
my $ctx = Test2::API::Context->new(
    trace => $trace,
    hub   => $hub,
);

my $e = $ctx->build_event('Ok', pass => 1, name => 'foo');
is($e->pass, 1, "Pass");
is($e->name, 'foo', "got name");
is_deeply($e->trace, $trace, "Got the trace info");
ok(!@$events, "No events yet");

$e = $ctx->send_event('Ok', pass => 1, name => 'foo');
is($e->pass, 1, "Pass");
is($e->name, 'foo', "got name");
is_deeply($e->trace, $trace, "Got the trace info");
is(@$events, 1, "1 event");
is_deeply($events, [$e], "Hub saw the event");
pop @$events;

$e = $ctx->ok(1, 'foo');
is($e->pass, 1, "Pass");
is($e->name, 'foo', "got name");
is_deeply($e->trace, $trace, "Got the trace info");
is(@$events, 1, "1 event");
is_deeply($events, [$e], "Hub saw the event");
pop @$events;

$e = $ctx->note('foo');
is($e->message, 'foo', "got message");
is_deeply($e->trace, $trace, "Got the trace info");
is(@$events, 1, "1 event");
is_deeply($events, [$e], "Hub saw the event");
pop @$events;

$e = $ctx->diag('foo');
is($e->message, 'foo', "got message");
is_deeply($e->trace, $trace, "Got the trace info");
is(@$events, 1, "1 event");
is_deeply($events, [$e], "Hub saw the event");
pop @$events;

$e = $ctx->plan(100);
is($e->max, 100, "got max");
is_deeply($e->trace, $trace, "Got the trace info");
is(@$events, 1, "1 event");
is_deeply($events, [$e], "Hub saw the event");
pop @$events;

$e = $ctx->skip('foo', 'because');
is($e->name, 'foo', "got name");
is($e->reason, 'because', "got reason");
ok($e->pass, "skip events pass by default");
is_deeply($e->trace, $trace, "Got the trace info");
is(@$events, 1, "1 event");
is_deeply($events, [$e], "Hub saw the event");
pop @$events;

$e = $ctx->skip('foo', 'because', pass => 0);
ok(!$e->pass, "can override skip params");
pop @$events;

# Test hooks

my @hooks;
$hub =  test2_stack()->top;
my $ref1 = $hub->add_context_init(sub { push @hooks => 'hub_init' });
my $ref2 = $hub->add_context_release(sub { push @hooks => 'hub_release' });
test2_add_callback_context_init(sub { push @hooks => 'global_init' });
test2_add_callback_context_release(sub { push @hooks => 'global_release' });

sub {
    push @hooks => 'start';
    my $ctx = context(on_init => sub { push @hooks => 'ctx_init' }, on_release => sub { push @hooks => 'ctx_release' });
    push @hooks => 'deep';
    my $ctx2 = sub {
        context(on_init => sub { push @hooks => 'ctx_init_deep' }, on_release => sub { push @hooks => 'ctx_release_deep' });
    }->();
    push @hooks => 'release_deep';
    $ctx2->release;
    push @hooks => 'release_parent';
    $ctx->release;
    push @hooks => 'released_all';

    push @hooks => 'new';
    $ctx = context(on_init => sub { push @hooks => 'ctx_init2' }, on_release => sub { push @hooks => 'ctx_release2' });
    push @hooks => 'release_new';
    $ctx->release;
    push @hooks => 'done';
}->();

$hub->remove_context_init($ref1);
$hub->remove_context_release($ref2);
@{Test2::API::_context_init_callbacks_ref()} = ();
@{Test2::API::_context_release_callbacks_ref()} = ();

is_deeply(
    \@hooks,
    [qw{
        start
        global_init
        hub_init
        ctx_init
        deep
        release_deep
        release_parent
        ctx_release_deep
        ctx_release
        hub_release
        global_release
        released_all
        new
        global_init
        hub_init
        ctx_init2
        release_new
        ctx_release2
        hub_release
        global_release
        done
    }],
    "Got all hook in correct order"
);

{
    my $ctx = context(level => -1);

    my $one = Test2::API::Context->new(
        trace => Test2::Util::Trace->new(frame => [__PACKAGE__, __FILE__, __LINE__, 'blah']),
        hub => test2_stack()->top,
    );
    is($one->_depth, 0, "default depth");

    my $ran = 0;
    my $doit = sub {
        is_deeply(\@_, [qw/foo bar/], "got args");
        $ran++;
        die "Make sure old context is restored";
    };

    eval { $one->do_in_context($doit, 'foo', 'bar') };

    is(context(level => -1, wrapped => -2), $ctx, "Old context restored");
    $ctx->release;
    $ctx->release;

    ok(!exception { $one->do_in_context(sub {1}) }, "do_in_context works without an original")
}

{
    like(exception { Test2::API::Context->new() }, qr/The 'trace' attribute is required/, "need to have trace");

    my $trace = Test2::Util::Trace->new(frame => [__PACKAGE__, __FILE__, __LINE__, 'foo']);
    like(exception { Test2::API::Context->new(trace => $trace) }, qr/The 'hub' attribute is required/, "need to have hub");

    my $hub = test2_stack()->top;
    my $ctx = Test2::API::Context->new(trace => $trace, hub => $hub);
    is($ctx->{_depth}, 0, "depth set to 0 when not defined.");

    $ctx = Test2::API::Context->new(trace => $trace, hub => $hub, _depth => 1);
    is($ctx->{_depth}, 1, "Do not reset depth");

    like(
        exception { $ctx->release },
        qr/release\(\) should not be called on a non-canonical context/,
        "Non canonical context, do not release"
    );
}

sub {
    like(
        exception { my $ctx = context(level => 20) },
        qr/Could not find context at depth 21/,
        "Level sanity"
    );

    ok(
        !exception {
            my $ctx = context(level => 20, fudge => 1);
            $ctx->release;
        },
        "Was able to get context when fudging level"
    );
}->();

sub {
    my ($ctx1, $ctx2);
    sub { $ctx1 = context() }->();

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings => @_ };
        $ctx2 = context();
        $ctx1 = undef;
    }

    $ctx2->release;

    is(@warnings, 1, "1 warning");
    like(
        $warnings[0],
        qr/^context\(\) was called to retrieve an existing context, however the existing/,
        "Got expected warning"
    );
}->();

sub {
    my $ctx = context();
    my $e = exception { $ctx->throw('xxx') };
    like($e, qr/xxx/, "got exception");

    $ctx = context();
    my $warnings = warnings { $ctx->alert('xxx') };
    like($warnings->[0], qr/xxx/, "got warning");
    $ctx->release;
}->();

sub {
    my $ctx = context;

    is($ctx->_parse_event('Ok'), 'Test2::Event::Ok', "Got the Ok event class");
    is($ctx->_parse_event('+Test2::Event::Ok'), 'Test2::Event::Ok', "Got the +Ok event class");

    like(
        exception { $ctx->_parse_event('+DFASGFSDFGSDGSD') },
        qr/Could not load event module 'DFASGFSDFGSDGSD': Can't locate DFASGFSDFGSDGSD\.pm/,
        "Bad event type"
    );
}->();

{
    my ($e1, $e2);
    my $events = intercept {
        my $ctx = context();
        $e1 = $ctx->ok(0, 'foo', ['xxx']);
        $e2 = $ctx->ok(0, 'foo');
        $ctx->release;
    };

    ok($e1->isa('Test2::Event::Ok'), "returned ok event");
    ok($e2->isa('Test2::Event::Ok'), "returned ok event");

    is($events->[0], $e1, "got ok event 1");
    is($events->[3], $e2, "got ok event 2");

    is($events->[2]->message, 'xxx', "event 1 diag 2");
}

sub {
    local $! = 100;
    local $@ = 'foobarbaz';
    local $? = 123;

    my $ctx = context();

    is($ctx->errno,       100,         "saved errno");
    is($ctx->eval_error,  'foobarbaz', "saved eval error");
    is($ctx->child_error, 123,         "saved child exit");

    $! = 22;
    $@ = 'xyz';
    $? = 33;

    is(0 + $!, 22,    "altered \$! in tool");
    is($@,     'xyz', "altered \$@ in tool");
    is($?,     33,    "altered \$? in tool");

    $ctx->release;

    is($ctx->errno,       100,         "restored errno");
    is($ctx->eval_error,  'foobarbaz', "restored eval error");
    is($ctx->child_error, 123,         "restored child exit");
}->();

done_testing;