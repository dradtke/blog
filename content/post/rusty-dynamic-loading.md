+++
date = "2016-03-08T14:48:13-06:00"
title = "Rusty Dynamic Loading"
draft = true
+++

# Introduction

One of the most useful game development tips that I've learned so far from
Casey Muratori's excellent Handmade Hero series of videos is how to [load game
code dynamically](https://www.youtube.com/watch?v=WMSBRk5WG58). Doing so
enables you to iterate very quickly, because you don't need to close your game,
re-compile, and re-start the whole thing each time you want to make a change.
However, Casey only shows you how to do it in C using Win32. Feeling inspired,
I set out to enable a similar dynamic loading mechanism in cross-platform Rust.

For those unfamiliar with the technique, the basic idea is to de-couple your
main loop from the update and render functions. Normally, everything is
compiled together into a single executable; in order to get the benefits of
dynamic code reloading, that needs to change. In particular, the code that
contains the update and render functions needs to be built as a dynamic
library, which is then accessed manually by the executable.

Even though this technique is primarily intended for game development, I'm
going to keep things simple by building something lame instead, so that it
doesn't require any fancy-pants dependencies like OpenGL. However, the basic
concepts are the same, no matter what you're actually doing with the code.

**NOTE:** these examples were tested with Rust 1.6. These examples may work
with other versions, and they may not. But they most likely will. Probably.

# Setting Up

So at a minimum, we need to create two projects: one executable entrypoint, and
one dynamic library. Anything in the entrypoint should be considered fixed;
any changes made to it will require you to kill the process and re-compile it.
Its entire purpose in life is to do any required initial setup, locate the
dynamic library that contains the important stuff, and run the main loop.

{{<highlight text>}}
.
├── game
│   ├── Cargo.toml
│   └── src
│       └── lib.rs
└── main
    ├── Cargo.toml
    └── src
        └── main.rs
{{</highlight>}}

Here, `game` is the all-important dynamic library that contains the meat of our
core logic, and `main` is the entrypoint.

Since the whole purpose of this post is to demonstrate how to set up a project
to use dynamic loading, most of it will focus on `main`. For demonstrative
purposes, the contents of `./game/src/lib.rs` will be:

{{<highlight rust>}}
#[no_mangle]
pub fn get_message() -> &'static str {
    "Hello, Dylib!"
}
{{</highlight>}}

The `no_mangle` attribute is necessary in order for this to work, for
reasons that will be demonstrated later.

The only other thing that's necessary is to make sure `game` is built as a
dynamic library. To do that, open up `./game/Cargo.toml` and add a section like
this:

{{<highlight text>}}
[lib]
name = "game"
crate-type = ["dylib"]
{{</highlight>}}

Build the project with Cargo and ensure that it generates a dynamic library
somewhere under `target` (for me it shows up under `target/debug`). If the
generated file ends in `.rlib`, then it was built as a statically-linked
library, which will not work; make sure you add the above `crate-type`
declaration before building.

The rest of this post will focus on `main`.

# Dependencies

The Rust team's approach to the standard library is to keep it fairly slim,
outsourcing pieces that used to be included to their own crates. Because of
that, we need to add a couple thing to `./main/Cargo.toml` (version numbers not
set in stone, but they're what I tested with):

{{<highlight text>}}
[dependencies]
dylib = "0.0.2"
notify = "^2.5.0"
{{</highlight>}}

1. `dylib` implements dynamic library support.
2. `notify` implements file system notifications.

# Dylib Baby Steps

Crack open `./main/src/main.rs` and let's get to work!

Before we can learn how to slice and dice, we first need to figure out how to
open a dynamic library in the first place. Fortunately, Rust makes this a
little simpler than C does (and cross-platform to boot):

{{<highlight rust>}}
extern crate dylib;

use dylib::DynamicLibrary;
use std::path::Path;

// Change according to your setup and platform. ".so"
// files represent dynamic libraries on Linux systems.
// This path assumes that your working directory at execution
// time is `./main`.
const LIB_PATH: &'static str = "../game/target/debug/libgame.so";

fn main() {
    let lib = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
        .unwrap_or_else(|error| panic!("{}", error));
}
{{</highlight>}}

This short program simply demonstrates how to obtain a handle to an existing
dynamic library. It's really quite straightforward, though I recommend being a
little more thoughtful with regards to error handling.

The second step, calling a function from the handle, is a little bit trickier,
but doesn't use very much code:

{{<highlight rust>}}
// In main(), right after opening the dynamic library.
let get_message: fn() -> &'static str = unsafe {
    std::mem::transmute(lib.symbol::<usize>("get_message").unwrap())
};
println!("message: {}", get_message());
{{</highlight>}}

There's a lot going on in these few lines, so let's break it down:

{{<highlight rust>}}
lib.symbol::<usize>("get_message").unwrap()
{{</highlight>}}

This piece of code is what actually looks up the `get_message` function from
our library handle. `symbol()` returns a raw, mutable pointer to
some type `T`, so we need to specify what type we expect the symbol to be. In
the case of functions, we need to request the address of the function as the
symbol type; `usize` represents an unsigned, architecture-sized pointer,
perfectly suited to be a memory address.

**NOTE:** This line is also why the function in `game` is marked `no_mangle`;
`DynamicLibrary` under the hood uses the platform's native C-based dynamic
library support, so the function names need to be available as C symbols in
order to be found.

{{<highlight rust>}}
unsafe { std::mem::transmute(...) }
{{</highlight>}}

`transmute()` is an escape hatch in Rust's type system. `symbol()` returns a
raw pointer, but we want a more usable type, so we need to tell the compiler
that it should simply transmute the type of the function pointer (`usize`) to
something more suitable. The type it gets transmuted to is determined by the
compiler's type inference mechanism.

Both `transmute()` and `symbol()` are marked as `unsafe` functions, so we need
to wrap the whole thing in `unsafe { ... }` in order for it to compile. It's
basically telling the compiler that we're shouldering the responsibility of
verifying the types ourselves, but only within that block.

Last but not least:

{{<highlight rust>}}
let get_message: fn() -> &'static str = ...;
{{</highlight>}}

After all that, what we really want is just a reference to a function that we
can call. By creating a new value whose type matches the one requested from the
library (which needs to be verified manually!) and assigning the symbol to it,
we're telling Rust that the function pointer really is a `fn() -> &'static
str`.

If all went well, running that program should print the following to your
screen:

{{<highlight text>}}
message: Hello, Dylib!
{{</highlight>}}

Hooray! We're now able to call functions from the dynamic library!

# Main Loop

Now that we can open and call functions from our library, the next step is to
put it all together and wrap it in a main loop.

{{<highlight rust>}}
extern crate dylib;

use dylib::DynamicLibrary;
use std::mem::transmute;
use std::path::Path;
use std::thread;
use std::time::Duration;

// Change according to your setup and platform. ".so"
// files represent dynamic libraries on Linux systems.
// This path assumes that your working directory at execution
// time is `./main`.
const LIB_PATH: &'static str = "../game/target/debug/libgame.so";

// Frames per second. For our examples, it's left at 1,
// but most games will have this at 30 or 60.
const FPS: u64 = 1;

fn main() {
    let lib = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
        .unwrap_or_else(|error| panic!("{}", error));

    let get_message: fn() -> &'static str = unsafe {
        transmute(lib.symbol::<usize>("get_message").unwrap())
    };

    let dur = Duration::from_millis(1000 / FPS);
    loop {
        thread::sleep(dur);
        println!("message: {}", get_message());
    }
}
{{</highlight>}}

Again, for simplicity's sake, this is kind of a poor man's main loop. Most of
the time you'll want to use something more event-driven, but `thread::sleep`
gets the job done here.

# Listening for Changes

The other big piece is to listen for changes to the library, so that we know
when to reload it. It *is* possible to just re-load the library every frame,
but that's so inefficient that it doesn't even deserve to be made fun of.

To help out with this, we're going to use the `notify` crate. First step is to
set up a watcher:

{{<highlight rust>}}
// Needs an "extern crate notify;" at the top of the file.
let (ns, nr) = std::sync::mpsc::channel();
let mut watcher = notify::new(ns).unwrap();
watcher.watch(LIB_PATH).unwrap();
{{</highlight>}}

This code sets up `nr` to be the receiver for any changes made to our library.
In order to use it, we need to periodically check if any events have occurred,
and if so, reload the library.

The top of the main loop, right after `thread::sleep()`, seems like a good
place to put it!

{{<highlight rust>}}
loop {
    thread::sleep(dur);

    // Note the use of try_recv() instead of recv(). The former
    // is non-blocking, which lets the loop proceed as normal
    // if there is nothing to act on.
    if let Ok(ref event) = nr.try_recv() {
        if let Ok(ref op) = event.op {
            if op.contains(notify::op::REMOVE) {
                // Reason for this line described below.
                watcher.watch(LIB_PATH).unwrap();
            } else {
                // Reload the library!
            }
        }
    }
}
{{</highlight>}}

## inotify

At this point in time, I'd like to take a detour and complain a little bit
about `inotify`. `inotify` is the primary means by which Linux systems listen
for file system events, and for the most part it works great, but there's one
catch: it sucks at watching binary files. And I mean it *sucks*. For whatever
reason, making a change to a binary file does not issue a `WRITE` event or
anything of the kind. What it does instead is issue two: `CHMOD` and `REMOVE`.
Why is this important? Well, when a file issues a `REMOVE` event, it's
automatically removed from the watcher. That means that when setting up a watch
on a shared library, you have to constantly listen for `REMOVE` events and
re-add it to the watcher each time, because otherwise you'll get one
notification that the file changed, and that's it. From what I can tell, this
isn't a problem with text files, which is its primary use case, but for binary
files you need to make sure that you're actually still listening for events.

Now, where was I?

# Reloading the Library

In order to reload the library, we need to be able to change it, so let's go
back and add a `mut` declaration:


{{<highlight rust>}}
// Allow the value of lib to change.
let mut lib = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
    .unwrap_or_else(|error| panic!("{}", error));

// This will need to be replaced as well.
let mut get_message: fn() -> &'static str = unsafe {
    transmute(lib.symbol::<usize>("get_message").unwrap())
};

let mut needs_reload = false;
{{</highlight>}}

Wait, what's that `needs_reload` doing there?

{{<highlight rust>}}
loop {
    thread::sleep(dur);

    if let Ok(ref event) = nr.try_recv() {
        if let Ok(ref op) = event.op {
            if op.contains(notify::op::REMOVE) {
                watcher.watch(LIB_PATH).unwrap();
            } else {
                let needs_reload = true; // A-ha!
            }
        }
    }


    if needs_reload && std::fs::metadata(LIB_PATH).unwrap().len() > 0 {
        // Reload the library.
        needs_reload = false;
    }
}
{{</highlight>}}

Sometimes, filesystem notifications are *too* efficient. Rather than re-loading
the library as soon as we've received an event, it's safer to double-check that
the file contains data first. I suspect that this is why `inotify` receives a
`REMOVE` event for binaries; that compilers under the hood delete the file
before writing out the new one; but in any case, without the use of
`needs_reload` and a verification that the library's size is non-empty, you'll
almost certainly run into errors, at least eventually. This approach is safer
and avoids most potential race conditions with the filesystem.

# Reloading the Library

The only thing that's left to do is reload the library itself. Regarding that,
there's good news, and there's bad news:

**The Good News:** It's actually quite easy to do.

**The Bad News:** Of all of the API exploring and testing it took for me to
develop a working solution, this is the part that took the longest to figure
out.

First, here's how to do it:

{{<highlight rust>}}
drop(lib);

lib = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
    .unwrap_or_else(|error| panic!("{}", error));

get_message = unsafe {
    transmute(lib.symbol::<usize>("get_message").unwrap())
};
{{</highlight>}}

The reason for the `drop()` is because, at least on Linux, the underlying
dynamic library implementation performs its own reference counting. What that
means is that, if you try to open a dynamic library that's already open
somewhere in your application, you'll receive a cached result. In order to
force the library to be completely re-loaded from disk, which is what we want,
we must first decrement the refcount back to 0. Rust's `DynamicLibrary` does
this decrement as part of the destructor, so we must first run the destructor
on the existing handle *before* opening it up again, or else we'll receive the
same handle back.

Now, the first time I tried this using `drop()`, I swear it didn't work, and I
ended up developing another solution that used a custom enum with `Open` and
`Closed` variants that forced the destructor to run indirectly. However, more
recent testing shows that calling `drop()` directly *does* work, and since
that's far and away the simpler solution, I figure I'll stick with that.

# The Full Solution

Check out the [gist](https://gist.github.com/dradtke/a13a7b3658463ca7d241) to
see all of this together in one solution.
