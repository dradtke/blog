+++
date = "2016-09-26"
title = "Rusty Dynamic Loading"
+++

# Introduction

One of my favorite things that I've learned so far from
Casey Muratori's excellent Handmade Hero series of videos is his demonstration
of how to [load game code dynamically](https://www.youtube.com/watch?v=WMSBRk5WG58).
This allows you to make changes to the running game without having to close the
existing process, which enables very rapid iteration during development.
However, Casey only shows you how to do it in C using Win32.
In this post, I will demonstrate how to achieve the same basic effect using
cross-platform Rust.

Even though this technique is primarily intended for game development, the purpose
of this post is to demonstrate how to utilize dynamic libraries to reload code on
the fly, which is a general technique that can be applied to any type of program
that wants to take advantage of it.

**NOTE:** This post assumes some basic familiarity with Rust and Cargo, and that you
have a working Rust development environment. If not,
[this](https://doc.rust-lang.org/book/getting-started.html) is a good place to
get started.

**UPDATE:** The end of this post now contains an updated final version using the
`libloading` crate instead of `dylib`, since apparently it's more actively maintained.
The rest of the post is left unchanged.

# Setting Up

In order for this to work, we first need to create a project defined by two halves:
an executable, and a dynamic library. In a real-world scenario, the dynamic
library will likely contain the vast majority of the project's code; the executable's
sole purpose is to delegate functionality to the library and to reload it
when necessary.

To get started, let's create two projects using Cargo. In a new folder, run the
following commands:

{{<highlight text>}}
$ cargo new app
$ cargo new --bin main
{{</highlight>}}

Running these commands should give you the following project structure:

{{<highlight text>}}
.
├── app
│   ├── Cargo.toml
│   └── src
│       └── lib.rs
└── main
    ├── Cargo.toml
    └── src
        └── main.rs
{{</highlight>}}

1. `app` is where the application logic lives, and will be built as a dynamic library.
2. `main` is the executable that will load `app` and use it.

## `app`

First, we need to make sure that `app` is configured to build a dynamic library.
To do that, open up `app/Cargo.toml` and add a few lines at the bottom of the
file:

{{<highlight text>}}
[lib]
crate-type = ["dylib"]
{{</highlight>}}

These lines specify that the project should be built as a dynamic library
rather than a static library, which is the default.

Now let's implement some absolutely critical logic for our application in
`app/src/lib.rs`:

{{<highlight rust>}}
#[no_mangle]
pub fn get_message() -> &'static str {
    "Hello, Dylib!"
}
{{</highlight>}}

Build the project with Cargo and ensure that it generates a dynamic library
(which will likely appear under `target/debug`) by checking the library's extension;
if it was built as an `.rlib` file, then make sure you have your `[lib]` section set
up correctly in `Cargo.toml`. The correct extension is `.so`, `.dll`, or `.dylib`
for Linux, Windows, or Mac, respectively.

Okay, we now have a dynamic library that implements our application code.
Let's see how we can access it.

# Hello World for Dylib

Let's switch our attention over to the `main` project. In order to work with dynamic
libraries, we first need to install the `dylib` crate, so add these lines to
`main/Cargo.toml` before moving on:

{{<highlight text>}}
[dependencies]
dylib = "0.0.2"
{{</highlight>}}

Now crack open `main/src/main.rs` in your editor of choice and let's get to work!
The first step is to use the `dylib` crate to retrieve a handle to the application
code:

{{<highlight rust>}}
extern crate dylib;

use dylib::DynamicLibrary;
use std::path::Path;

// Change according to your setup and platform.
// This path assumes a Linux system, and that your working
// directory is `main`.
const LIB_PATH: &'static str = "../app/target/debug/libapp.so";

fn main() {
    let app = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
        .unwrap_or_else(|error| panic!("{}", error));
}
{{</highlight>}}

(Note that in a more real-world scenario, you'll probably want to handle
errors more gracefully than just panicking.)

Now that we have a handle to the application library, how do we use it? This part
is actually a little tricky since we lose a lot of type information
when crossing process boundaries. The only utility provided for looking
up a function in a dynamic library is the `symbol()` method, which
returns a raw pointer to some type that you specify. But what type
should we specify, and how do we safely dereference the raw pointer?

There are actually a few ways that you can do this, but
after some wrangling with the type system, this is what I consider to be
the best approach:

{{<highlight rust>}}
// In main(), right after opening the dynamic library.
let get_message: fn() -> &'static str = unsafe {
    std::mem::transmute(app.symbol::<usize>("get_message").unwrap())
};
println!("message: {}", get_message());
{{</highlight>}}

Since function references are just pointers, the first step is to look
up the `get_message` symbol as a raw, untyped pointer (`*mut usize`),
and then use `transmute()` to tell the Rust compiler to magically
convert it to the type inferred by the variable we're setting the
result to; in this case, `fn() -> &'static str`, which we know matches
the signature of the method's implementation, even if the compiler
doesn't.

Note that this is also why we need to add the `#[no_mangle]` attribute above the
function definition. By default, the Rust compiler
[mangles function names](https://en.wikipedia.org/wiki/Name_mangling#Rust),
which we need to prevent in order to look it up by name.

If all went well, then you should now be able to run the program
and get the following output:

{{<highlight text>}}
message: Hello, Dylib!
{{</highlight>}}

# Listening for Changes

Now that we can call functions from our application, we now need to create a
main loop. Let's modify the code from above to repeatedly call `get_message()`,
which will later be updated to dynamically pick up changes to that method:

{{<highlight rust>}}
loop {
    std::thread::sleep(std::time::Duration::from_secs(1));
    println!("message: {}", get_message());
}
{{</highlight>}}

But how do we know when to reload the application code? There are a couple
different ways to do this:

1. Use filesystem notifications (the `notify` crate). 
2. Query file metadata on each iteration, and reload if the file has changed.

Filesystem notifications provide the least amount of overhead in the main loop,
but behave rather strangely when applied to binary files, so we'll go with the
second option. The most straightforward and cross-platform way to do this is
to check the applications's modification time, and reload it if the version on
disk has been modified since it was last loaded into memory.

The first thing to do is to modify the existing code to make the `app` and
`get_message` variables mutable, and to add a new mutable variable to keep track
of the modification time.

{{<highlight rust>}}
let mut app = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
    .unwrap_or_else(|error| panic!("{}", error));

let mut last_modified = std::fs::metadata(LIB_PATH).unwrap()
    .modified().unwrap();

let mut get_message: fn() -> &'static str = unsafe {
    std::mem::transmute(app.symbol::<usize>("get_message").unwrap())
};
{{</highlight>}}

Then we can modify the main loop to this:

{{<highlight rust>}}
let dur = std::time::Duration::from_secs(1);
loop {
    std::thread::sleep(dur);
    if let Ok(Ok(modified)) = std::fs::metadata(LIB_PATH)
                             .map(|m| m.modified())
    {
        if modified > last_modified {
            // TODO: Reload the application.
            last_modified = modified;
        }
    }
    println!("message: {}", get_message());
}
{{</highlight>}}

# Reloading the Library

The only thing that's left to do is to load the application's new contents into
memory. A first pass might look like this:

{{<highlight rust>}}
app = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
    .unwrap_or_else(|error| panic!("{}", error));

get_message = unsafe {
    transmute(app.symbol::<usize>("get_message").unwrap())
};
{{</highlight>}}

This, however, won't work. The correct implementation looks like this:

{{<highlight rust>}}
drop(app);

app = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
    .unwrap_or_else(|error| panic!("{}", error));

get_message = unsafe {
    transmute(app.symbol::<usize>("get_message").unwrap())
};
{{</highlight>}}

The reason for the `drop()` is because most platforms (verified on Mac and
Linux, and I assume Windows behaves similarly) cache the contents of each
dynamic library loaded within the application, so that if it's requested
elsewhere, the application won't have to reload it from disk. Unfortunately,
that's exactly what we want. In order to force the application to be reloaded
from disk, we need to force the `DynamicLibrary` destructor to run first
so that the reference count drops to 0, which causes the library to be unloaded
from memory. _Then_ we can reload it and get the contents as they are on disk.

# The Full Solution

For those of you who skipped straight to the bottom, here's the full solution
for `main`:

{{<highlight rust>}}
extern crate dylib;

use dylib::DynamicLibrary;
use std::path::Path;

const LIB_PATH: &'static str = "../app/target/debug/libapp.so";

fn main() {
    // Open the application library.
    let mut app = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
        .unwrap_or_else(|error| panic!("{}", error));

    // Look up the functions that we want to use.
    let mut get_message: fn() -> &'static str = unsafe {
        std::mem::transmute(
            app.symbol::<usize>("get_message").unwrap()
        )
    };

    // Record the time at which it was last modified.
    let mut last_modified = std::fs::metadata(LIB_PATH).unwrap()
        .modified().unwrap();

    // Begin looping once per second.
    let dur = std::time::Duration::from_secs(1);
    loop {
        std::thread::sleep(dur);
        if let Ok(Ok(modified)) = std::fs::metadata(LIB_PATH)
                                  .map(|m| m.modified())
        {
            // Check to see if the library has been modified
            // recently.
            if modified > last_modified {
                // Force the library's destructor to run, to avoid
                // retrieving a cached handle when reopening.
                drop(app);

                // Re-open the application library.
                app = DynamicLibrary::open(Some(Path::new(LIB_PATH)))
                    .unwrap_or_else(|error| panic!("{}", error));

                // Re-look up the functions that we want to use.
                get_message = unsafe {
                    std::mem::transmute(
                        app.symbol::<usize>("get_message").unwrap()
                    )
                };

                last_modified = modified;
            }
        }

        // Call your application methods here.
        println!("message: {}", get_message());
    }
}
{{</highlight>}}

Start this running, then modify `app` to print out `G'day, Dylib!` and build it.
The output of `main` should adjust accordingly without skipping a beat!

# Final Note: Sharing Custom Data

One big problem that any serious use of this technique will quickly run into
is the sharing of custom data types. Both the application library and the
running executable need to have access to the same custom type definitions
in order to meaningfully pass the data between the two.

Fortunately, it's not actually too difficult to do. If you add the application
library as a dependency to `main`, then you can access any types defined there.
To do that, just add a couple lines to `main/Cargo.toml`:

{{<highlight rust>}}
[dependencies.app]
path = "../app"
{{</highlight>}}

Then add an `extern crate app;` line at the top of `main/src/main.rs`, and
you're free to use any custom type defined within the `app` crate in your
method definitions. The only caveat is that `main` must be restarted after
any changes to your data types, but those should be changing must less frequently
than the code that uses them.

# Update: Using `libloading`

Since writing this post, it has been brought to my attention that the `dylib`
crate is not actively maintained, and that `libloading` is a better alternative.
Here's one way to achieve the same effect using `libloading`:

{{<highlight rust>}}
extern crate app;
extern crate libloading;

use libloading::{Library, Symbol};

const LIB_PATH: &'static str = "../app/target/debug/libapp.so";

struct Application(Library);
impl Application {
    fn get_message(&self) -> &'static str {
        unsafe {
            let f = self.0.get::<unsafe extern fn() -> &'static str>(
                b"get_message\0"
            ).unwrap();
            f()
        }
    }
}

fn main() {
    let mut app = Application(Library::new(LIB_PATH)
        .unwrap_or_else(|error| panic!("{}", error)));

    let mut last_modified = std::fs::metadata(LIB_PATH).unwrap()
        .modified().unwrap();

    let dur = std::time::Duration::from_secs(1);
    loop {
        std::thread::sleep(dur);
        if let Ok(Ok(modified)) = std::fs::metadata(LIB_PATH)
                                  .map(|m| m.modified())
        {
            if modified > last_modified {
                drop(app);
                app = Application(Library::new(LIB_PATH)
                    .unwrap_or_else(|error| panic!("{}", error)));
                last_modified = modified;
            }
        }
        println!("message: {}", app.get_message());
    }
}
{{</highlight>}}

The primary difference here is the introduction of the `Application` type, which
is just a wrapper around the dynamic library. The reason for this is that `libloading`,
being a safer alternative to `dylib`, pretty strictly enforces how long a symbol
reference can be valid for; if you fetch and maintain a reference the same
way we did with `dylib`, the compiler will bark at you when you try to do anything
else with the library, since it's borrowed until the reference goes out of scope.
The `Application` type wraps the library and looks up symbol references on the fly,
which gets around the problem with the possibility of a slight performance hit.
If the performance hit becomes unacceptable, it is possible to maintain a symbol
reference by using `into_raw()`, but that's left as an exercise for the reader.
