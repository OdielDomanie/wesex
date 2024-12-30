defmodule Wesex.MockServer do
  @moduledoc """
  A mock server that takes a `WebSock` behaviour, for use with `Wesex.MockAdapter`.

  Starts in the `closed` state, and stops when the connection is closed after being opened.
  """

  use GenServer, restart: :temporary

  @doc """
  Starts the MockServer process.

  `opts` is a keyword list with:
  * `:websock` - `WebSock` implementing module
  * `:init_arg` - Passed to `c:WebSock.init/1`, default `nil`
  * `:uri` - `t:URI.t/0` struct that `Wesex.Connection.connect/5` must match to.
  * `:send_to` - pid to send events to.
      This is the process that should `receive` the events and call `Wesex.Connection.event/2`
      with a connection that has the `Wesex.MockAdapter` adapter.
  """
  def start_link(opts) do
    {mock_opts, other_opts} = Keyword.split(opts, [:websock, :init_arg, :uri, :send_to])
    GenServer.start_link(__MODULE__, mock_opts, other_opts)
  end

  @doc """
  Returns the `WebSock` state.
  """
  def dump_state(server) do
    GenServer.call(server, :dump_state)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      status: :closed,
      websock: Keyword.fetch!(opts, :websock),
      websock_state: opts[:init_arg],
      uri: Keyword.fetch!(opts, :uri),
      send_to: Keyword.fetch!(opts, :send_to)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:dump_state, _from, state) do
    {:reply, state.websock_state, state}
  end

  def handle_call(msg, _, state) do
    handle_msg(msg, state)
  end

  defp handle_msg({:connect, uri, headers}, %{status: :closed} = state) do
    if uri == state.uri do
      state = put_in(state[:headers], headers)

      case state.websock.init(state.websock_state) do
        result when elem(result, 0) in [:ok, :push, :reply] ->
          {:push, messages, websock_state} = normalize_push_result(result)
          state = %{state | websock_state: websock_state, status: :open}
          Kernel.send(state.send_to, {:mock_server_messages, messages})

          {:reply, :ok, state}

        result when elem(result, 0) == :stop ->
          {:stop, reason, {code, stop_data}, messages, websock_state} =
            normalize_close_result(result)

          reply = messages ++ [{:close, code, stop_data}]

          state =
            %{state | status: :closing, websock_state: websock_state}
            |> Map.put(:stop_reason, reason)

          Kernel.send(state.send_to, {:mock_server_messages, reply})

          {:reply, :ok, state}
      end
    else
      {:reply, {:error, {:bad_uri, uri, state.uri}}, state}
    end
  end

  defp handle_msg({msg_type, _data}, state)
       when state.status != :open and msg_type in [:text, :binary] do
    reason = {:received_when_status, state.status}
    {:stop, reason, {:error, reason}}
  end

  defp handle_msg({msg_type, data}, state)
       when state.status == :open and msg_type in [:text, :binary] do
    case state.websock.handle_in({data, opcode: msg_type}, state.websock_state) do
      result when elem(result, 0) in [:ok, :push, :reply] ->
        {:push, messages, websock_state} = normalize_push_result(result)
        state = %{state | websock_state: websock_state}
        {:reply, messages, state}

      result when elem(result, 0) == :stop ->
        {:stop, reason, {code, stop_data}, messages, websock_state} =
          normalize_close_result(result)

        reply = messages ++ [{:close, code, stop_data}]

        state =
          %{state | status: :closing, websock_state: websock_state}
          # status: :closing will have a stop reason
          |> Map.put(:stop_reason, reason)

        {:reply, reply, state}
    end
  end

  defp handle_msg({:ping, data}, state) when state.status == :open do
    {:reply, [pong: data], state}
  end

  defp handle_msg(:ping, state) when state.status == :closing do
    {:reply, [], state}
  end

  defp handle_msg(:pong, state) when state.status in [:open, :closing] do
    {:reply, [], state}
  end

  defp handle_msg({:close, code, _reason}, state) when state.status == :open do
    reply = [{:close, code, nil}]
    state = Map.put(state, :remote_closed, true)
    {:stop, :normal, reply, state}
  end

  defp handle_msg({:close, _code, _reason}, state) when state.status == :closing do
    {:stop, state.stop_reason, [], state}
  end

  @impl true
  def terminate(reason, state) do
    reason =
      cond do
        reason == :normal -> :normal
        state[:remote_closed] -> :remote
        match?({:shutdown, _}, reason) -> :shutdown
        true -> {:error, reason}
      end

    if Code.ensure_loaded?(state.websock) and function_exported?(state.websock, :terminate, 2) do
      state.websock.terminate(reason, state.websock_state)
    end
  end

  @impl true
  def handle_info(info, state) do
    case state.websock.handle_info(info, state.websock_state) do
      result when elem(result, 0) in [:ok, :push, :reply] ->
        {:push, messages, websock_state} = normalize_push_result(result)
        state = %{state | websock_state: websock_state}
        Kernel.send(state.send_to, {:mock_server_messages, messages})
        {:noreply, state}

      result when elem(result, 0) == :stop ->
        {:stop, reason, {code, stop_data}, messages, websock_state} =
          normalize_close_result(result)

        reply = messages ++ [{:close, code, stop_data}]

        state =
          %{state | status: :closing, websock_state: websock_state}
          # status: :closing will have a stop reason
          |> Map.put(:stop_reason, reason)

        Kernel.send(state.send_to, {:mock_server_messages, reply})
        {:noreply, state}
    end
  end

  defp normalize_push_result({:push, msgs, websock_state}) do
    {:push, messages_as_list(msgs), websock_state}
  end

  defp normalize_push_result({:ok, websock_state}) do
    {:push, [], websock_state}
  end

  defp normalize_push_result({:reply, _, msgs, websock_state}) do
    {:push, messages_as_list(msgs), websock_state}
  end

  defp normalize_close_result({:stop, reason, close_detail, msgs, websock_state}) do
    code_reason = close_detail_to_code_data(close_detail)
    msgs = messages_as_list(msgs)
    {:stop, reason, code_reason, msgs, websock_state}
  end

  defp normalize_close_result({:stop, reason, close_detail, websock_state}) do
    code_reason = close_detail_to_code_data(close_detail)
    {:stop, reason, code_reason, [], websock_state}
  end

  defp normalize_close_result({:stop, reason, websock_state}) do
    code =
      case reason do
        :normal ->
          1000

        {:shutdown, _} ->
          1000

        _ ->
          nil
      end

    {:stop, reason, {code, nil}, [], websock_state}
  end

  defp close_detail_to_code_data(code) when is_integer(code), do: {code, nil}
  defp close_detail_to_code_data({code, data}), do: {code, data}

  defp messages_as_list({type, msg}) when type in [:text, :binary] do
    [{type, msg}]
  end

  defp messages_as_list(msgs) when is_list(msgs), do: msgs
end
