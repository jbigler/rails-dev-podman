# frozen_string_literal: true

require "test_helper"

class MarkdownTest < Minitest::Test
  MD = Wt::Views::Markdown

  def text(rows) = rows.map { |r| r.sum("") { it.text }.rstrip }
  def width(row) = row.sum { RatatuiRuby::Text.width(it.text) }

  REPLY = <<~MD
    ## Summary

    The **counts query** scans `tasks` by *status_bucket*.

    | Service | State | Port |
    |---|:---:|---:|
    | rails | running | 3014 |
    | postgres | healthy | 5446 |

    ```ruby
    def foo
        bar   # spaces kept
    end
    ```
  MD

  def test_table_columns_line_up_with_alignment
    rows = text(MD.rows(REPLY, 80))
    i = rows.index { it.start_with?("Service") }
    assert_equal ["Service  │  State  │ Port",
                  "─────────┼─────────┼─────",
                  "rails    │ running │ 3014",
                  "postgres │ healthy │ 5446"], rows[i, 4]
  end

  def test_a_table_wider_than_the_row_wraps_cells_instead_of_overflowing
    md = "| a | b |\n|---|---|\n| #{'word ' * 30}| x |\n"
    rows = MD.rows(md, 40)
    assert(rows.all? { width(it) <= 40 }, text(rows).inspect)
    assert_operator rows.size, :>, 3
    assert(text(rows).all? { it.include?("│") || it.include?("┼") }, "every row keeps the column separator")
  end

  def test_code_keeps_spaces_and_is_not_reflowed
    rows = text(MD.rows(REPLY, 80))
    assert_includes rows, "    bar   # spaces kept"
    assert_includes rows, "def foo"
    refute(rows.any? { it.include?("```") })
  end

  def test_an_unterminated_fence_runs_to_the_end
    rows = text(MD.rows("```\na  b\n**not bold**", 40))
    assert_equal ["a  b", "**not bold**"], rows
  end

  def test_inline_markup_becomes_style_not_characters
    segs = MD.rows("The **counts** and `tasks` and *x* and [PR](http://u)", 80).first
    assert_equal "The counts and tasks and x and PR (http://u)", segs.sum("") { it.text }
    assert segs.find { it.text == "counts" }.style[:bold]
    assert_equal :cyn, segs.find { it.text == "tasks" }.style[:fg]
    assert segs.find { it.text == "x" }.style[:italic]
    assert segs.find { it.text == "PR" }.style[:underline]
  end

  def test_soft_breaks_join_and_lists_hang
    rows = text(MD.rows("one\ntwo\n\n- first item that is long enough to wrap\n- [x] done", 20))
    assert_equal "one two", rows[0]
    assert_equal ["• first item that is", "  long enough to", "  wrap", "☑ done"], rows[2..]
  end

  def test_every_row_fits_its_width
    [12, 30, 80].each do |w|
      MD.rows(REPLY + "\n#{'x' * 200}\n\n> #{'quoted ' * 20}", w).each { assert_operator width(it), :<=, w }
    end
  end

  def test_preview_is_plain_first_line
    assert_equal "Summary", MD.preview(REPLY)
    assert_equal "Ran the counts query", MD.preview("- Ran the **counts** query\n")
  end
end

class ChatMarkdownTest < Minitest::Test
  def test_agent_reply_renders_as_a_table_in_the_chat
    s = Wt::AgentSession.new(slug: "tasks", connection: :connected,
                             transcript: [Wt::TranscriptEntry.new(role: :agent, text: MarkdownTest::REPLY)])
    m = model.with(sessions: { "tasks" => s })
    m = m.with(ui: m.ui.with(screen: :chat, chat_slug: "tasks", width: 187, height: 50))
    screen = render(m, width: 187, height: 50)
    assert_includes screen, "rails    │ running │ 3014"
    refute_includes screen, "|---"
    refute_includes screen, "**counts query**"
  end
end
