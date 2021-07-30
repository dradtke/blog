+++
date = "2021-07-30"
title = "Hot Reload in Uno and GTK"
enableInlineShortcodes = true
+++

# Uno

While playing around with Microsoft's Uno Platform, I discovered its super-neat [XAML Hot
Reload](https://platform.uno/docs/articles/features/working-with-xaml-hot-reload.html) feature. It
basically does exactly what you think it would; while the app is running, changes made to any XAML
file will be reflected automatically, without needing to re-build anything. This is basically the
desktop development equivalent of [LiveReload](http://livereload.com/), and is a great way to
tighten the feedback loop and enable faster development.

Unfortunately, my laptop only runs Linux, and their documentation requires you to use the Visual
Studio Add-in in order to use hot reload. After some searching, however, I discovered Matheus
Castello's
[post](https://microhobby.com.br/blog/2020/11/30/vs-code-xaml-preview-embedded-linux-dotnet-core/)
about getting hot reload to work on embedded Linux. This was very promising, but he did not go into
any detail about how he got it working, only providing some videos of his Visual Studio Code
extension.

However, after some work, I was able to get it working in an editor-agnostic way. Here's Uno Hot
Reload in action using nothing but tmux and Neovim:

{{< video src="/videos/hot-reload-uno-gtk/Uno Hot Reload.mp4" type="video/mp4" >}}

The bottom-left pane is running the Uno Remote Control Host, which lives within Uno's source tree,
using something like this:

{{< highlight bash >}}
# As of writing, the Remote Control Host requires .NET Core 3.
# When using asdf with the dotnet-core plugin, you can set the correct
# version with:
$ asdf install dotnet-core 3.1.401 && asdf shell dotnet-core 3.1.401
$ source ~/.asdf/plugins/dotnet-core/set-dotnet-home.bash

# Now build and run the Remote Control Host.
# "${uno}" refers to the path of the Uno source tree.
$ cd "${uno}"/src/Uno.UI.RemoteControl.Host
$ "${DOTNET_ROOT}"/dotnet build
$ cd bin/Debug/netcoreapp3.1
$ ./Uno.UI.RemoteControl.Host --httpPort=9876
{{< /highlight >}}

(The fully-working script lives in my dotfiles
[here](https://git.sr.ht/~damien/dotfiles/tree/master/item/vim/bin/uno-hot-reload))

The bottom-right pane is running the Skia.Gtk target, configured to use the Remote Control Host
running on port 9876 (or whatever port number you specify):

{{< highlight bash >}}
$ dotnet build -property:UnoRemoteControlPort=9876 && \
    dotnet run --no-build
{{< /highlight >}}

Note that [`dotnet run`](https://docs.microsoft.com/en-us/dotnet/core/tools/dotnet-run) does not
support specifying additional project properties as arguments, but `dotnet build` does, so this
command separates out the build and run steps. The alternative would be to open the project file
and add the `UnoRemoteControlPort` property manually, which works too, but would need to be updated
any time you change the port or want to disable the hot reload feature.

# GTK

Having seen how useful hot reload can be for desktop development, I started to wonder how to
accomplish something similar using plain GTK. It supports an XML-based [UI definition
language](https://docs.gtk.org/gtk4/class.Builder.html#a-gtkbuilder-ui-definition) too, so it
shouldn't be too difficult to support a similar feature.

It requires a little bit of extra code, but I can confirm that it is indeed possible!

{{< video src="/videos/hot-reload-uno-gtk/GTK Hot Reload.mp4" type="video/mp4" >}}

This version of hot reload does not use a separate server; rather, the application itself monitors
the UI file for changes, and when a change is detected, it re-invokes the rendering function. My
example is in C, but it's pretty short, and the same technique can be easily transferred to any
language with GTK bindings:

{{< highlight c >}}
// main.c

#include <gtk/gtk.h>
#include "hot-reload.c"

static void on_load_main_window(
	GtkBuilder *builder,
	GtkApplicationWindow *window
) {
	GObject *content_box = gtk_builder_get_object(builder, "content");
	gtk_window_set_child(GTK_WINDOW(window), GTK_WIDGET(content_box));
}

static void on_unload_main_window(
	GtkBuilder *builder,
	GtkApplicationWindow *window
) {
	g_info("Unloading main window");
	// Nothing to do explicitly (I think) if just replacing the window's child
}

static void activate(GtkApplication *app, gpointer user_data) {
	GtkWidget *window = gtk_application_window_new(app);
	gtk_widget_set_size_request(window, 400, 300);
	hot_reload(
		"main.ui",
		(GFunc)on_load_main_window,
		(GFunc)on_unload_main_window,
		window
	);
	gtk_window_present(GTK_WINDOW(window));
}
{{< /highlight >}}

The `hot_reload()` method creates a builder for `main.ui`, invokes the specified load callback, and
then constructs a `GFileMonitor` that listens for changes to it. When a change is detected, the
unload callback is invoked (if provided), and then the builder is re-created, and the load callback
re-invoked.

The full example can be seen [here](https://git.sr.ht/~damien/gtk-hot-reload), though I am not a
professional in C, so don't be too surprised if I missed a memory leak somewhere. It is intended to
serve primarily as a proof-of-concept, rather than a full-fledged implementation.

<!-- vim: set tw=100: -->
