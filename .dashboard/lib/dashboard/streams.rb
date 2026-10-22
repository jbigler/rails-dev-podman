# frozen_string_literal: true

require "erb"

module Dashboard
  # Hub events as Turbo Stream frames, and the SSE framing that carries them to
  # a page's <turbo-stream-source>.
  module Streams
    # Seconds between the comments that keep an idle stream open (and find a gone client).
    PING = 15
    PING_FRAME = ": ping\n\n"
    # The list container's id (views/_list.erb).
    LIST = "worktrees"
    QUESTIONS = { permission: "needs permission", question: "question" }.freeze

    # <turbo-stream> with the given attributes (escaped; nil ones left out) around a
    # <template> of `html`, which is already HTML. No template without html.
    def self.turbo(action, target, html = nil, **attrs)
      attributes = { action:, target:, **attrs }.filter_map { |key, value| %( #{key}="#{ERB::Util.html_escape(value)}") unless value.nil? }
      "<turbo-stream#{attributes.join}>#{"<template>#{html}</template>" if html}</turbo-stream>"
    end

    # One SSE message: each line of `payload` as a data: line, then a blank line.
    def self.sse(payload) = payload.split(/\r\n?|\n/).map { "data: #{it}\n" }.join << "\n"

    # → [String] frames for one Hub event, rendered from `state`. sub: the page's
    # Subscription (whose row is selected). listed: the worktree names the page's
    # list holds; a row event whose worktree joined or left it re-renders the whole
    # list. repo: what the header shows.
    def self.frames(event, state, sub, listed: nil, repo: nil)
      kind, name = event
      case kind
      when :row then [row(name, state, sub, listed)]
      when :detail then [detail(name, state)]
      when :gone then [gone]
      when :header then [turbo("replace", "header", Render.header(state, repo:))]
      when :notify then notify(name, state)
      when :job then [] # Task 7
      else raise ArgumentError, "unknown event: #{event.inspect}"
      end
    end

    def self.row(name, state, sub, listed)
      wt = find(state, name)
      if wt.nil? || (listed && !listed.include?(name))
        turbo("replace", LIST, Render.list(state, sub.viewing))
      else
        turbo("replace", Render.dom_id("row", name), Render.row(wt, selected: name == sub.viewing))
      end
    end

    def self.detail(name, state)
      wt = find(state, name)
      wt ? turbo("replace", "detail", Render.detail(wt, state)) : gone
    end

    def self.gone = turbo("replace", "detail", %(<section id="detail" class="detail empty"><p class="muted">worktree removed</p></section>))

    # A browser notification when the agent still waits; none once it has moved on.
    def self.notify(name, state)
      agent = find(state, name)&.agent
      return [] unless agent.is_a?(Agent) && agent.needs_input?

      [turbo("notify", nil, title: "#{name}: #{QUESTIONS.fetch(agent.state)}", body: agent.message.to_s, tag: name)]
    end

    def self.find(state, name) = state.worktrees.find { it.name == name }
    private_class_method :row, :detail, :gone, :notify, :find
  end
end
