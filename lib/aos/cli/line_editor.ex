defmodule AOS.CLI.LineEditor do
  @moduledoc false
  require Bitwise

  @esc <<27>>
  @backspace 127
  @ctrl_h 8
  @ctrl_c 3
  @ctrl_d 4

  def apply_key(state, :up), do: move_history(state, :up)
  def apply_key(state, :down), do: move_history(state, :down)
  def apply_key(state, :left), do: move_cursor(state, :left)
  def apply_key(state, :right), do: move_cursor(state, :right)
  def apply_key(state, :backspace), do: handle_backspace(state)
  def apply_key(state, :delete), do: handle_delete(state)

  def read_line(prompt, history \\ []) do
    initial_state = %{
      prompt: prompt,
      buffer: "",
      # Grapheme-based cursor position
      cursor: 0,
      history: Enum.uniq(history),
      history_index: nil,
      draft: ""
    }

    with {:ok, stty_state} <- stty("-g"),
         :ok <- set_tty_mode(),
         :ok <- render(initial_state) do
      result = loop(initial_state)
      restore_tty_mode(stty_state)

      case result do
        {:ok, buffer} -> {:ok, String.normalize(buffer, :nfc)}
        other -> other
      end
    else
      _ ->
        fallback_read(prompt)
    end
  end

  defp loop(state) do
    case IO.binread(:stdio, 1) do
      :eof ->
        IO.write("\n")
        :eof

      <<@ctrl_c>> ->
        IO.write("^C\n")
        :interrupt

      <<@ctrl_d>> ->
        IO.write("\n")
        :eof

      <<char>> when char in [@ctrl_h, @backspace] ->
        state |> handle_backspace() |> rerender_and_continue()

      # Enter
      <<13>> ->
        IO.write("\n")
        {:ok, state.buffer}

      # Newline
      <<10>> ->
        IO.write("\n")
        {:ok, state.buffer}

      @esc ->
        state |> handle_escape_sequence() |> rerender_and_continue()

      <<char_code>> ->
        text = read_full_utf8(char_code)

        if text == "" or char_code < 32 do
          rerender_and_continue(state)
        else
          state |> insert_text(text) |> rerender_and_continue()
        end
    end
  end

  defp read_full_utf8(first_byte) do
    cond do
      first_byte < 128 -> <<first_byte>>
      Bitwise.band(first_byte, 0xE0) == 0xC0 -> <<first_byte>> <> (IO.binread(:stdio, 1) || "")
      Bitwise.band(first_byte, 0xF0) == 0xE0 -> <<first_byte>> <> (IO.binread(:stdio, 2) || "")
      Bitwise.band(first_byte, 0xF8) == 0xF0 -> <<first_byte>> <> (IO.binread(:stdio, 3) || "")
      true -> ""
    end
  end

  defp handle_backspace(%{cursor: 0} = state), do: state

  defp handle_backspace(state) do
    graphemes = String.graphemes(state.buffer)
    cursor = min(max(state.cursor, 0), length(graphemes))
    {left, right} = Enum.split(graphemes, cursor)
    new_buffer = String.normalize(Enum.join(Enum.drop(left, -1) ++ right), :nfc)
    %{state | buffer: new_buffer, cursor: cursor - 1}
  end

  defp insert_text(state, text) do
    graphemes = String.graphemes(state.buffer)
    cursor = min(max(state.cursor, 0), length(graphemes))
    {left, right} = Enum.split(graphemes, cursor)
    new_buffer = String.normalize(Enum.join(left ++ [text] ++ right), :nfc)
    new_left_len = length(String.graphemes(String.normalize(Enum.join(left ++ [text]), :nfc)))
    %{state | buffer: new_buffer, cursor: new_left_len}
  end

  defp handle_escape_sequence(state) do
    case IO.binread(:stdio, 2) do
      <<"[A">> ->
        move_history(state, :up)

      <<"[B">> ->
        move_history(state, :down)

      <<"[C">> ->
        move_cursor(state, :right)

      <<"[D">> ->
        move_cursor(state, :left)

      <<"[3">> ->
        # consume ~
        _ = IO.binread(:stdio, 1)
        handle_delete(state)

      _ ->
        state
    end
  end

  defp move_cursor(state, :left), do: %{state | cursor: max(state.cursor - 1, 0)}

  defp move_cursor(state, :right) do
    len = length(String.graphemes(state.buffer))
    %{state | cursor: min(state.cursor + 1, len)}
  end

  defp handle_delete(state) do
    graphemes = String.graphemes(state.buffer)
    cursor = min(max(state.cursor, 0), length(graphemes))
    {left, right} = Enum.split(graphemes, cursor)
    new_buffer = String.normalize(Enum.join(left ++ Enum.drop(right, 1)), :nfc)
    %{state | buffer: new_buffer}
  end

  defp move_history(state, direction) do
    case direction do
      :up ->
        idx =
          if state.history_index == nil,
            do: length(state.history) - 1,
            else: state.history_index - 1

        if idx >= 0 do
          buf = Enum.at(state.history, idx)

          %{
            state
            | history_index: idx,
              draft: if(state.history_index == nil, do: state.buffer, else: state.draft),
              buffer: buf,
              cursor: length(String.graphemes(buf))
          }
        else
          state
        end

      :down ->
        if state.history_index == nil do
          state
        else
          idx = state.history_index + 1

          if idx < length(state.history) do
            buf = Enum.at(state.history, idx)
            %{state | history_index: idx, buffer: buf, cursor: length(String.graphemes(buf))}
          else
            %{
              state
              | history_index: nil,
                buffer: state.draft,
                cursor: length(String.graphemes(state.draft))
            }
          end
        end
    end
  end

  defp rerender_and_continue(state) do
    render(state)
    loop(state)
  end

  defp render(state) do
    # Clear line using carriage return and clear-to-end-of-line
    IO.write("\r\e[K")
    IO.write(state.prompt <> state.buffer)

    # Move to absolute column for maximum reliability
    graphemes = String.graphemes(state.buffer)
    left_part = Enum.take(graphemes, state.cursor)

    # +1 because terminal columns are 1-indexed
    target_col = display_width(state.prompt) + display_width(Enum.join(left_part)) + 1

    IO.write("\e[#{target_col}G")
    :ok
  end

  defp display_width(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme_width(g) end)
  end

  defp grapheme_width(g) do
    case String.to_charlist(g) do
      [cp | _] ->
        # Hangul Jamo
        # CJK Ideographs
        # Hangul Syllables
        # CJK Compatibility
        # CJK Compatibility Forms
        # Fullwidth
        if (cp >= 0x1100 && cp <= 0x11FF) ||
             (cp >= 0x2E80 && cp <= 0x9FFF) ||
             (cp >= 0xAC00 && cp <= 0xD7AF) ||
             (cp >= 0xF900 && cp <= 0xFAFF) ||
             (cp >= 0xFE30 && cp <= 0xFE4F) ||
             (cp >= 0xFF00 && cp <= 0xFF60) do
          2
        else
          1
        end

      [] ->
        0
    end
  end

  defp set_tty_mode do
    case stty("raw", "-echo", "iutf8") do
      {:ok, _} -> :ok
      _ -> stty("raw", "-echo")
    end
  end

  defp restore_tty_mode(stty_state), do: stty(stty_state)

  defp stty(a, b \\ nil, c \\ nil) do
    args = Enum.reject([a, b, c], &is_nil/1)

    case System.cmd("stty", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> {:error, :stty}
    end
  end

  defp fallback_read(prompt) do
    case IO.gets(prompt) do
      nil -> :eof
      input -> {:ok, String.trim_trailing(input, "\n")}
    end
  end
end
