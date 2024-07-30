defmodule Wesex.Websocket do
  @moduledoc """
  Functional websocket handling.
  """
  alias __MODULE__.{Opening, Open, Closing, Closed}
  alias Mint.{HTTP, WebSocket}

  @type dataframe :: {:text, String.t()} | {:binary, binary()}
  @type closed :: Closed.t()
  @type opening :: Opening.t()
  @type open :: Open.t()
  @type closing :: Closing.t()

  @type close_reason :: %{optional(:reason) => String.t(), code: nil | pos_integer()}

  @doc """
  Start opening the connection.
  """
  @spec open(closed, URI.t(), Mint.Types.headers(), timeout, keyword() | nil, keyword() | nil) ::
          {:ok, Opening.t()} | {:error, closed, reason :: any}
  defdelegate open(
                closed,
                url,
                headers,
                timeout \\ Opening.default_timeout(),
                con_opts \\ [],
                ws_opts \\ []
              ),
              to: Closed

  @spec send(dataframe(), open) :: {:ok, open} | {:error, closed, reason :: any}
  def send(dataframe, %Open{} = state) do
    {:ok, ws, frame_bin} =
      WebSocket.encode(state.ws, dataframe)

    case WebSocket.stream_request_body(state.con, state.ws_ref, frame_bin) do
      {:ok, con} ->
        {:ok, %{state | con: con, ws: ws}}

      {:error, con, reason} ->
        state = Open.fail(%{state | con: con, ws: ws})
        {:error, state, reason}
    end
  end

  @doc """
  Initiated closing.
  """
  @spec close(open, close_reason) :: closing | closed
  def close(%Open{} = state, close_reason, close_timeout \\ 5_000) do
    case send_close(close_reason, state.con, state.ws, state.ws_ref) do
      {:ok, con, ws} ->
        Closing.new(%{state | con: con, ws: ws}, :local, close_timeout)

      {:error, con, ws, _reason} ->
        Open.fail(%{state | con: con, ws: ws})
    end
  end

  @doc """
  Passes a received message to the websocket struct.
  Returns a list of events and the updated websocket.
  """
  @spec stream(msg :: any, opening | open | closing) ::
          {[event], opening | open | closing | closed} | :unknown
        when event:
               {:dataframe, reference(), dataframe}
               | {:closed, reference(), :remote_initiated, close_reason}
               | {:closed, reference(), :local_initiated, close_reason}
               | {:closed, reference(), :error, reason :: any}
               | {:opening, reference(), :error, reason :: any}
               | {:opening, reference(), :done}
  def stream(msg, state)

  def stream(_, %Closed{}), do: :unknown

  def stream({:ping_time, ws_ref}, %Open{ws_ref: ws_ref, ponged: true} = state) do
    state = %{state | ponged: false}

    case send_ping(state.con, state.ws, state.ws_ref) do
      {:ok, con, ws} ->
        ping_timer = Process.send_after(self(), {:ping_time, ws_ref}, state.ping_intv)
        {[], %{state | con: con, ws: ws, ping_timer: ping_timer}}

      {:error, con, ws, reason} ->
        state = Open.fail(%{state | con: con, ws: ws})
        event = {:closed, :error, reason}
        {[event], state}
    end
  end

  def stream({:ping_time, ws_ref}, %Open{ws_ref: ws_ref, ponged: false} = state) do
    state = Open.fail(state)
    event = {:closed, ws_ref, :error, :ping_timeout}
    {[event], state}
  end

  def stream({:close_timeout, ws_ref}, %Closing{ws_ref: ws_ref, initiator: :local} = state) do
    event = {:closed, :local_initiated, state.remote_close_reason}
    state = Closing.fail(state)
    {[event], state}
  end

  def stream({:close_timeout, ws_ref}, %Closing{ws_ref: ws_ref, initiator: :remote} = state) do
    state = Closing.fail(state)
    event = {:closed, :remote_initiated, state.remote_close_reason}
    {[event], state}
  end

  def stream({:open_timeout, ws_ref}, %Opening{} = state) do
    state = Opening.fail(state)
    event = {:opening, ws_ref, :error, :timeout}
    {[event], state}
  end

  def stream(msg, %Opening{} = state) do
    case WebSocket.stream(state.con, msg) do
      :unknown ->
        :unknown

      {:error, con, reason, _resps} ->
        event = {:opening, state.ws_ref, :error, reason}
        state = Opening.fail(%{state | con: con})
        {[event], state}

      {:ok, con, resps} ->
        state = %{state | con: con}

        if HTTP.open?(state.con, :write) do
          case opening_resps(resps, state) do
            {:ok, %Opening{} = state} ->
              {[], state}

            {:ok, %Open{} = state, other_resps} ->
              {events, state} = do_open_or_closing_frames(other_resps, state)
              event = {:opening, state.ws_ref, :done}
              {[event | events], state}

            {:error, %Closed{}, reason} ->
              event = {:opening, state.ws_ref, :error, reason}
              state = Opening.fail(%{state | con: con})
              {[event], state}
          end
        else
          event = {:opening, state.ws_ref, :error, :closed}
          state = Opening.fail(state)
          {[event], state}
        end
    end
  end

  def stream(msg, %Open{} = state) do
    case WebSocket.stream(state.con, msg) do
      :unknown ->
        :unknown

      {:error, con, reason, _resps} ->
        event = {:closed, state.ws_ref, :error, reason}
        state = Open.fail(%{state | con: con})
        {[event], state}

      {:ok, con, resps} ->
        state = %{state | con: con}
        do_open_or_closing_frames(resps, state)
    end
  end

  def stream(msg, %Closing{} = state) do
    case WebSocket.stream(state.con, msg) do
      :unknown ->
        :unknown

      {:error, con, _reason, _resps} ->
        iniator =
          case state.initiator do
            :local -> :local_initiated
            :remote -> :remote_initiated
          end

        event = {:closed, state.ws_ref, iniator, state.remote_close_reason}
        state = Closing.fail(%{state | con: con})
        {[event], state}

      {:ok, con, resps} ->
        state = %{state | con: con}
        do_open_or_closing_frames(resps, state)
    end
  end

  defp do_open_or_closing_frames(resps, state) when state.__struct__ in [Open, Closing] do
    {frames, ws} = resps_to_frames(resps, state.ws, state.ws_ref)
    state = %{state | ws: ws}
    {events, state} = process_frames(frames, state)

    if state.__struct__ not in [Open, Closing] or HTTP.open?(state.con, :read) do
      {events, state}
    else
      case state do
        %Open{} ->
          event = {:closed, state.ws_ref, :error, :closed}
          {events ++ [event], Open.fail(state)}

        %Closing{remote_close_reason: close_reason, initiator: :local} ->
          event = {:closed, state.ws_ref, :local_initiated, close_reason}
          {events ++ [event], Closing.fail(state)}

        %Closing{remote_close_reason: close_reason, initiator: :remote} ->
          event = {:closed, state.ws_ref, :remote_initiated, close_reason}
          {events ++ [event], Closing.fail(state)}
      end
    end
  end

  @spec opening_resps([Mint.Types.response()], opening()) ::
          {:ok, opening} | {:ok, open, [...]} | {:error, closed, reason :: any}
  defp opening_resps([], state), do: {:ok, state}

  defp opening_resps(
         [{:status, ws_ref, _} = status_resp | rest],
         %Opening{status_resp: nil, headers_resp: nil, done_resp: nil, ws_ref: ws_ref} = state
       ) do
    state = %{state | status_resp: status_resp}
    opening_resps(rest, state)
  end

  defp opening_resps(
         [{:headers, ws_ref, _} = headers_resp | rest],
         %Opening{headers_resp: nil, done_resp: nil, ws_ref: ws_ref} = state
       ) do
    state = %{state | headers_resp: headers_resp}
    opening_resps(rest, state)
  end

  # TODO
  # defp opening_resps(
  #        [{:data, ws_ref, data} | rest],
  #        %Opening{done_resp: nil, ws_ref: ws_ref} = state
  #      ) do
  #   Opening.finish_opening(state, rest)
  # end

  defp opening_resps(
         [{:done, ws_ref} = done_resp | rest],
         %Opening{done_resp: nil, ws_ref: ws_ref} = state
       ) do
    state = %{state | done_resp: done_resp}
    Opening.finish_opening(state, rest)
  end

  defp opening_resps(
         [resp | rest],
         %Opening{} = state
       ) do
    state = Opening.fail(state)
    {:error, state, [resp | rest]}
  end

  defp process_frames([], state), do: {[], state}

  defp process_frames([{data_type, data} | rest], state) when data_type in [:text, :binary] do
    event = {:dataframe, state.ws_ref, {data_type, data}}
    {rest_events, state} = process_frames(rest, state)
    {[event | rest_events], state}
  end

  defp process_frames([{:pong, _} | rest], %Open{} = state) do
    state = %{state | ponged: true}
    process_frames(rest, state)
  end

  defp process_frames([{:pong, _} | rest], state) do
    process_frames(rest, state)
  end

  defp process_frames([{:ping, _} | rest], %Open{} = state) do
    if HTTP.open?(state.con, :write) do
      case send_pong(state.con, state.ws, state.ws_ref) do
        {:ok, con, ws} ->
          state = %{state | con: con, ws: ws}
          process_frames(rest, state)

        {:error, con, ws, reason} ->
          event = {:closed, state.ws_ref, :error, reason}
          state = Open.fail(%{state | con: con, ws: ws})
          {[event], state}
      end
    else
      process_frames(rest, state)
    end
  end

  defp process_frames([{:ping, _} | rest], %Closing{} = state) do
    process_frames(rest, state)
  end

  defp process_frames([{:close, code, reason} | _rest], %Open{} = state) do
    state = Closing.new(state, :remote)
    state = %{state | remote_close_reason: %{code: code, reason: reason}}

    case send_close(%{code: code}, state.con, state.ws, state.ws_ref) do
      {:ok, con, ws} ->
        state = %{state | con: con, ws: ws}
        {[], state}

      {:error, con, ws, _reason} ->
        event = {:closed, state.ws_ref, :remote_initiated, %{code: code, reason: reason}}
        state = Closing.fail(%{state | con: con, ws: ws})
        {[event], state}
    end
  end

  defp process_frames([{:close, code, reason} | _rest], %Closing{initiator: :local} = state) do
    state = %{state | remote_close_reason: %{code: code, reason: reason}}
    {[], state}
  end

  defp resps_to_frames([], ws, _), do: {[], ws}

  defp resps_to_frames([{:data, ws_ref, frame_bin} | rest], ws, ws_ref) do
    {:ok, ws, frames} = WebSocket.decode(ws, frame_bin)
    {rest_frames, ws} = resps_to_frames(rest, ws, ws_ref)
    {frames ++ rest_frames, ws}
  end

  defp send_pong(con, ws, ws_ref) do
    {:ok, ws, frame_bin} = WebSocket.encode(ws, :pong)

    case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
      {:ok, con} -> {:ok, con, ws}
      {:error, con, reason} -> {:error, con, ws, reason}
    end
  end

  defp send_ping(con, ws, ws_ref) do
    {:ok, ws, frame_bin} = WebSocket.encode(ws, :ping)

    case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
      {:ok, con} -> {:ok, con, ws}
      {:error, con, reason} -> {:error, con, ws, reason}
    end
  end

  defp send_close(close_reason, con, ws, ws_ref) do
    {:ok, ws, frame_bin} =
      WebSocket.encode(ws, {:close, close_reason.code, close_reason[:reason] || ""})

    case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
      {:ok, con} -> {:ok, con, ws}
      {:error, con, reason} -> {:error, con, ws, reason}
    end
  end
end
