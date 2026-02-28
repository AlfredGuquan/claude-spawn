# claude-spawn Script (English)

## 1. Hook (~15s)

Hey everyone, today I want to show you a little tool I built called claude-spawn. It lets you run multiple Claude Code sessions in parallel, with shared context and isolated workspaces.

I'm in Claude Code right now, working on a task. I want to explore three different directions at the same time. All I need is one command —

(Screen: type /fork, three panes open simultaneously)

Just like that, three independent sessions. Each one inherits my full conversation history, and each one has its own git worktree — completely isolated.

## 2. The Pain Point (~20s)

If you've used Claude Code, you know the feeling: you're deep in a session, you've built up a ton of context, and then you realize — there's something else you need to work on too.

So what do you do? Open a new terminal, start another Claude, and copy over the background info — write a handoff doc, or just copy-paste manually. You become the messenger between two AIs.

And worse — if both sessions are editing files at the same time, they step on each other. Now you're dealing with merge conflicts.

## 3. How It Works (~40s)

claude-spawn solves this. It gives you two commands.

First, /new. You tell it what the new session should do, and it automatically distills the relevant context from your current conversation into a prompt, then launches a clean session in a new iTerm2 pane. You can also have it show you what it's going to pass over, so you can review before it sends. No manual handoff, no copy-paste — one step.

Second, /fork. This one's more direct — you describe in plain English what you want to do in parallel, and it forks your current session into that many panes. Each pane gets your full conversation history and picks up right where you left off.

The key thing is — whether it's /new or /fork, every new session runs in its own git worktree. Your main branch stays clean, and parallel agents never step on each other's files.

If you just want it to research first without touching code, you can add --plan to start the new session in plan mode.

## 4. Live Demo (~60s)

Let me show you how it works.

(Screen: typing command)

I'm typing /fork, and telling it the three things I want to do in parallel.

(Wait for panes to open)

There — iTerm2 just split into three panes. Each one is an independent Claude Code session, carrying all my previous conversation context.

Let's look at the file system.

(Switch to terminal, show worktree list)

You can see it automatically created three git worktrees. Each forked session works in its own directory. That's why they can all edit files at the same time without conflicts — each agent is working on an independent copy of the codebase.

Here's something cool. Let me go into one of the forked sessions —

(Demo nested fork inside a fork session)

Inside this session, I can /fork or /new again. It creates new worktrees based on the current one. That's nesting. You can split off more parallel sessions anytime, based on how complex your task gets.

## 5. Wrap Up + CTA (~15s)

So in short, claude-spawn takes Claude Code from doing one thing at a time to running multiple lines of work in parallel. Context transfers automatically, files stay isolated.

GitHub link is in the description. Setup is just three symlinks. If you try it out, I'd love to hear your feedback on GitHub.
