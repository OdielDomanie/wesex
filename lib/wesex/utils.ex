defmodule Wesex.Utils do
  defmacro flush_timer(timer, pattern) do
    quote do
      _ = Process.cancel_timer(unquote(timer), async: false)

      receive do
        unquote(pattern) -> :flush
      after
        0 -> nil
      end
    end
  end

  def state_of_return(ret) do
    case elem(ret, 0) do
      :ok -> elem(ret, 1)
      :noreply -> elem(ret, 1)
      :reply -> elem(ret, 2)
      :stop -> elem(ret, 2)
    end
  end

  def nest_state_in_return(ret, map, key) do
    state_idx =
      case elem(ret, 0) do
        :ok -> 1
        :noreply -> 1
        :reply -> 2
        :stop -> 2
      end

    state = elem(ret, state_idx)
    wrapping_state = Map.put(map, key, state)
    put_elem(ret, state_idx, wrapping_state)
  end
end
