# ob-gptel

An Org Babel backend for [gptel](https://github.com/karthink/gptel).

I've been using GPTel a lot lately, for many different tasks, and wanted
a way to embed AI conversations right into my Org documents. ob-gptel
does this -- you write a prompt in a `#+begin_src gptel` block, press
`C-c C-c`, and the response appears in the results. It's fully
asynchronous, so Emacs doesn't block while waiting.

Thanks to some late night pairing with Karthik (author of GPTel),
ob-gptel handles multi-turn conversations, preset configurations,
context injection, and dry-run mode for inspecting API payloads without
sending them.

## Requirements

- Emacs 25.1+
- [Org mode](https://orgmode.org/) 9.0+
- [gptel](https://github.com/karthink/gptel) 0.9.8.5+

## Installation

### Using straight.el

```emacs-lisp
(straight-use-package
 '(ob-gptel :type git :host github :repo "jwiegley/ob-gptel"))
```

### Manual

Clone this repository, add it to your load path, and require it:

```emacs-lisp
(add-to-list 'load-path "/path/to/ob-gptel")
(require 'ob-gptel)
```

## Setup

Register `gptel` as a Babel language:

```emacs-lisp
(org-babel-do-load-languages
 'org-babel-load-languages
 '((gptel . t)))
```

For completion of header argument names and values in gptel blocks:

```emacs-lisp
(add-hook 'completion-at-point-functions 'ob-gptel-capf nil t)
```

Or with `use-package`:

```emacs-lisp
(use-package ob-gptel
  :config
  (add-to-list 'org-babel-load-languages '(gptel . t))
  (defun ob-gptel-setup-completions ()
    (add-hook 'completion-at-point-functions
              'ob-gptel-capf nil t))
  :hook (org-mode . ob-gptel-setup-completions))
```

## Usage

### Basic query

```org
#+begin_src gptel
What is the capital of France?
#+end_src

#+RESULTS:
The capital of France is Paris.
```

### With parameters

```org
#+begin_src gptel :model gpt-4 :temperature 0.7 :max-tokens 150
Write a haiku about Emacs.
#+end_src
```

### System messages

```org
#+begin_src gptel :system "You are a helpful coding assistant."
How do I define a major mode in Emacs?
#+end_src
```

### Multi-turn conversations

There are two ways to build conversations. The `:prompt` header argument
references a named block, sending its body and result as a user/assistant
turn:

```org
#+name: setup
#+begin_src gptel :system "You are a math tutor."
What is the Pythagorean theorem?
#+end_src

#+RESULTS: setup
a^2 + b^2 = c^2

#+begin_src gptel :prompt setup
Can you give me an example?
#+end_src
```

The `:session` argument collects all preceding blocks that share the same
session name:

```org
#+begin_src gptel :session my-chat
Tell me about Emacs.
#+end_src

#+begin_src gptel :session my-chat
What about its history?
#+end_src
```

### Presets

If you've configured gptel presets, you can use them:

```org
#+begin_src gptel :preset claude
Explain monads simply.
#+end_src
```

### Dry run

Inspect the API payload without actually sending a request:

```org
#+begin_src gptel :dry-run yes
What would this request look like?
#+end_src
```

### Generating source blocks

In a literate DevOps context, you can have gptel generate commands:

```org
#+begin_src gptel :preset gpt :wrap src sh
GNU find command to search /tmp for files with 2+ hard-links.
Show only the final command.
#+end_src

#+RESULTS:
#+begin_src sh
find /tmp -type f -links +1
#+end_src
```

## Header arguments

| Argument       | Default     | Description                                |
|----------------|-------------|--------------------------------------------|
| `:model`       | nil         | Model to use (e.g., `gpt-4`)              |
| `:temperature` | nil         | Sampling temperature (0.0--2.0)            |
| `:max-tokens`  | nil         | Maximum tokens in response                 |
| `:system`      | nil         | System message                             |
| `:backend`     | nil         | gptel backend name                         |
| `:preset`      | nil         | gptel preset name                          |
| `:prompt`      | nil         | Named block for conversation context       |
| `:session`     | nil         | Session name for multi-turn conversations  |
| `:context`     | nil         | Files to include as context                |
| `:format`      | `"org"`     | Output format: `"markdown"` or `"org"`     |
| `:dry-run`     | nil         | Inspect payload without sending            |
| `:results`     | `"replace"` | Standard Org Babel results handling        |
| `:exports`     | `"both"`    | Standard Org Babel export control          |

## Development

This project uses [Nix](https://nixos.org/) for reproducible builds and
development.

```bash
# Enter development shell
nix develop

# Run all checks
nix flake check

# Build the package
nix build

# Format code
nix run .#format
```

[Lefthook](https://github.com/evilmartians/lefthook) handles pre-commit
hooks. Once inside `nix develop`:

```bash
lefthook install
```

## License

BSD 3-Clause. See [LICENSE.md](LICENSE.md).
