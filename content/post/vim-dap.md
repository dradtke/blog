+++
date = "2020-03-22"
title = "Debug Adapter Protocol for Vim"
draft = true
+++

Anyone else who prefers to use a text editor such as Vim, even when conventional
wisdom says that you should use an IDE, is also probably a big fan of the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol/),
which decouples the kind of intelligence that IDE's provide from the editor
itself. This enables any text editor able and willing to implement the protocol
to provide features similar to an IDE, notably Visual Studio Code.

However, I recently learned about the
[Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/),
which is similar, but is intended to provide a bridge between debuggers and
editors so that any text editor able and willing to implement the protocol is
compatible with any debuggers that either implement the protocol directly, or
more likely, have an _adapter_ that implements the protocol for them. Hence the
name.

Unfortunately, while there exist several Vim plugins implementing the Language
Server Protocol
([LanguageClient-neovim](https://github.com/autozimu/LanguageClient-neovim/),
[vim-lsp](https://github.com/prabirshrestha/vim-lsp/),
[coc.nvim](https://github.com/neoclide/coc.nvim)), there are comparatively few
that implement the Debug Adapter Protocol.
[vimspector](https://github.com/puremourning/vimspector) is the only other one
that I could find.

## Enter `vim-dap`

It's still a work-in-progress, but I have been spending some time on a new Vim
plugin implementing the protocol, [vim-dap](https://github.com/dradtke/vim-dap).
As of writing it is not as fully-featured as vimspector, but it also differs
pretty heavily in terms of user interface. Vimspector features a traditional
debugger UI with windows for scopes, variables, watches, and a debug console. By
contrast, `vim-dap` places a bigger emphasis on terminal friendliness. It
integrates with tmux (and in the future, Neovim's built-in terminal) to provide
only two additional windows beyond the text you're editing: one for program
output, and one to provide a REPL that evaluates what you type in the context of
the running program.
