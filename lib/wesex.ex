defmodule Wesex do
  @moduledoc """
  Documentation for `Wesex`.
  """

  require Mint.HTTP
  alias Wesex.Open
  alias Wesex.Opening
  alias Mint.HTTP
  alias Mint.WebSocket
  import Wesex.Utils, only: [flush_timer: 2]

  defmodule Closed do
    @moduledoc """
    The client is not connected.
    """
    @type t :: %__MODULE__{}
    defstruct []
  end

  defmodule Opening do
    @moduledoc """
    The client is in the process of connecting and opening.

    The fields are private.
    """
    @type t :: %__MODULE__{
            # Returns {:ok, Open} or {:error, Closed, reason}
            open_task: Task.t(),
            reply_to: GenServer.from()
          }
    defstruct [:open_task, :reply_to]
  end

  defmodule Open do
    @moduledoc """
    The websocket connection is ready to send and receive data.
    """
    @type t :: %__MODULE__{
            con: Mint.HTTP.t(),
            ws: Mint.WebSocket.t(),
            ws_ref: Mint.Types.request_ref(),
            ponged: boolean(),
            ping_timer: reference()
          }
    defstruct [:con, :ws, :ws_ref, :ping_timer, ponged: true]

    @doc false
    # Closes the connection, flush-cancels the timer.
    def fail(%__MODULE__{ping_timer: ping_timer, ws_ref: ws_ref, con: con}) do
      {:ok, _} = HTTP.close(con)
      _ = flush_timer(ping_timer, {:ping_timer, ^ws_ref})
      %Wesex.Closed{}
    end
  end

  defmodule Closing do
    @moduledoc """
    The client has sent a close frame, and waiting for the server reply.
    """
    @close_timeout 5000
    @type t :: %__MODULE__{
            con: Mint.HTTP.t(),
            ws: Mint.WebSocket.t(),
            ws_ref: Mint.Types.request_ref(),
            close_timer: reference(),
            remote_close_reason: nil | Wesex.close_reason()
          }
    defstruct [:con, :ws, :ws_ref, :close_timer, remote_close_reason: nil]

    @doc false
    # New closing state from `Open`. Flush-cancels timer, sets new timer, does not send close frame.
    # If `Closing` was given, return as is.
    def new(open_or_closing, close_timeout \\ @close_timeout, timer_dest \\ :self)

    def new(
          %Open{con: con, ping_timer: ping_timer, ws: ws, ws_ref: ws_ref},
          close_timeout,
          timer_dest
        ) do
      _ = flush_timer(ping_timer, {:ping_timer, ^ws_ref})

      dest = if timer_dest == :self, do: self(), else: timer_dest
      close_timer = Process.send_after(dest, {:close_timeout, ws_ref}, close_timeout)
      %__MODULE__{close_timer: close_timer, con: con, ws: ws, ws_ref: ws_ref}
    end

    def new(%Closing{} = c, _, _), do: c

    @doc false
    # Closes the connection, flush-cancels the timer.
    def fail(%__MODULE__{close_timer: close_timer, ws_ref: ws_ref, con: con}) do
      {:ok, _} = HTTP.close(con)
      _ = flush_timer(close_timer, {:close_timeout, ^ws_ref})
      %Wesex.Closed{}
    end
  end

  @type state :: Closed.t() | Opening.t() | Open.t() | Closing.t()

  @type con :: HTTP.t()
  @type data_frame :: {:text, String.t()} | {:binary, binary()}

  @type close_reason :: %{optional(:reason) => nil | String.t(), code: pos_integer()}
  @typedoc """
  Headers and transport opts to be merged in.
  """
  @type open_opts :: [{:headers, [{String.t(), String.t()}]} | {:transport_opts, keyword()}]

  @ping_interval 10_000

  @doc """
  Open a websocket connection.

  Url scheme must be "https".
  """
  @spec call_open(GenServer.server(), URI.t() | String.t(), open_opts(), timeout()) ::
          :ok | {:error, any()}
  def call_open(server, url, open_opts, timeout \\ @ping_interval) do
    GenServer.call(server, {:open, url, open_opts}, timeout)
  end

  @doc """
  Open a websocket connection.
  """
  @spec call_send(GenServer.server(), data_frame()) ::
          :ok | {:error, any()}
  def call_send(server, type_data, timeout \\ @ping_interval) do
    GenServer.call(server, {:send, type_data}, timeout)
  end

  def init_state(_opts), do: %Closed{}

  @doc """
  GenServer-like implementation for handle_call.

  If matches, returns `{result, return}`, where `result` explains the result of the call,
  and `return` is a `GenServer.handle_call/3` return term.

  If there is no match, returns `false` instead.

  Possible results are:
    * `:opening`: Opening handshake is initiated, the caller has not been replied to yet.
    * `{:send, :ok, {type, data}}`: Data is sent.
    * `{:send, :error, {type, data}, reason}`: Data could not be sent.
  """

  @spec handle_call({:open, URI.t() | String.t(), open_opts}, GenServer.from(), Closed.t()) ::
          {:opening, {:noreply, Opening.t()}}

  @spec handle_call({:send, data_frame()}, GenServer.from(), Open.t()) ::
          {{:send, :ok, data_frame()}, {:reply, :ok, Open}}
          | {{:send, :error, data_frame(), reason :: any}, {:reply, {:error, any}, Closed.t()}}

  @spec handle_call(any, any, any) :: false

  def handle_call({:open, url, opts}, from, closed) do
    t = Task.async(fn -> open(closed, url, self(), opts) end)

    {:opening, {:noreply, %Opening{open_task: t, reply_to: from}}}
  end

  def handle_call({:send, {type, data}}, _, %Open{} = state) do
    case send_data(state, {type, data}) do
      {:ok, %Open{} = state} ->
        {{:send, :ok, data}, {:reply, :ok, state}}

      {:failed, %Closed{} = state, reason} ->
        {{:send, :error, data, reason}, {:reply, {:error, reason}, state}}
    end
  end

  def handle_call(_, _, _), do: false

  @doc """
  GenServer-like implementation for handle_info.

  If matches, returns `{result, return}`, where `result` explains the result of the call,
  and `return` is a `GenServer.handle_info/2` return term.

  If there is no match, returns `false` instead.
    * `{:open, result}`: Opening handshake is completed, the caller has been replied to.
      * `:ok`: Handshake is successful.
      * `{:error, reason}`: The handshake failed and the state is now `Wesex.Closed`.
                            `reason` is `t:any/0`
    * `{:send_ping, :ok}`: Ping was sent after a planned interval.
    * `{:send_ping, :error, reason}`: Planned ping could not be sent and the connection is failed.
    * `{:receive, data_frames, status}`: List of `t:data_frame/0` were received.
      `status` can be:
      * `:ok`: Connection continues as is.
      * `{:sent_close, close_reason}`: The client has also sent a close frame.
          Might be due a protocol error, or because the server has sent a close frame
          but TCP is not closed yet..
      * `{:closed, close_reason}`: The websocket was closed properly.
      * `{:failed, reason}`: The connection was failed due to an error. `reason` is `t:any/0`.
    * `{:receive, data_frames, :failed, close_reason}`: Data frames were received.
        Due to some error the client closed the connection.
    * `:ping_timeout`: The server did not send a pong response in time. The connection is failed.
    * `:remote_close_timeout`: When `Wesex.Closing`, the remote did not respond with a close code in time.
    * `{:remote_con_timeout, remote_close_reason}`: When `Wesex.Closing`, the remote did respond with a close code,
        but failed to close the TCP connection in time.
  """
  def handle_info({ref, result}, %Opening{open_task: %Task{ref: ref}, reply_to: from}) do
    _ = Process.demonitor(ref, [:flush])

    case result do
      {:ok, %Open{} = state} ->
        {:ok, con} = HTTP.controlling_process(state.con, self())
        {:ok, con} = HTTP.set_mode(con, :active)
        state = %{state | con: con}

        ping_timer = Process.send_after(self(), {:ping_timer, state.ws_ref}, @ping_interval)
        state = %Open{state | ping_timer: ping_timer}

        :ok = GenServer.reply(from, :ok)
        {{:open, :ok}, {:noreply, state}}

      {:error, %Closed{} = state, reason} ->
        reply = {:error, reason}
        :ok = GenServer.reply(from, reply)
        {{:open, reply}, {:noreply, state}}
    end
  end

  def handle_info(
        {:ping_timer, ws_ref},
        %Open{ws_ref: ws_ref, ponged: true} = state
      ) do
    case send_ping(state) do
      {:ok, %Open{} = state} ->
        new_timer = Process.send_after(self(), {:ping_timer, state.ws_ref}, @ping_interval)
        state = %Open{state | ponged: false, ping_timer: new_timer}

        {{:send_ping, :ok}, {:noreply, state}}

      {:error, %Closed{} = state, reason} ->
        {{:send_ping, :error, reason}, {:noreply, state}}
    end
  end

  def handle_info(
        {:ping_timer, ws_ref},
        %Open{ws_ref: ws_ref, ponged: false} = state
      ) do
    state = Open.fail(state)
    {:ping_timeout, {:noreply, state}}
  end

  def handle_info(msg, state) when is_struct(state, Open) or is_struct(state, Closing) do
    case recv_msg(state, msg) do
      {data_frames, {status, state}} ->
        {{:receive, data_frames, status}, {:noreply, state}}

      :unknown ->
        false
    end
  end

  def handle_info({:close_timeout, ws_ref}, %Closing{ws_ref: ws_ref} = state) do
    closed = Closing.fail(state)

    case state.remote_close_reason do
      nil -> {:remote_close_timeout, {:noreply, closed}}
      remote_close_reason -> {{:remote_con_timeout, remote_close_reason}, {:noreply, closed}}
    end
  end

  defp http_scheme("http"), do: :http
  defp http_scheme("https"), do: :https
  defp http_to_ws_scheme(:http), do: :ws
  defp http_to_ws_scheme(:https), do: :wss

  @doc """
  Starts a websocket connection.

  `url` must have the "https" scheme.
  """
  @spec open(Closed.t(), URI.t() | String.t(), opts) ::
          {:ok, Open.t()} | {:error, Closed.t(), reason :: term}
        when opts: [{:headers, list} | {:transport_opts, keyword()}]

  def open(%Closed{}, url, controlling_pid, opts \\ [headers: [], transport_opts: []]) do
    {:ok, %URI{scheme: scheme, host: address, port: port, path: path, query: query}} =
      URI.new(url)

    full_path = %URI{path: path, query: query} |> URI.to_string()

    with {:ok, con} <-
           HTTP.connect(http_scheme(scheme), address, port,
             mode: :passive,
             transport_opts: opts[:transport_opts] || []
           ),
         {:ok, con, req_ref} <-
           WebSocket.upgrade(
             http_to_ws_scheme(http_scheme(scheme)),
             con,
             full_path,
             opts[:headers] || []
           ),
         {:ok, con, resps, []} <- receive_resp(con, req_ref),
         [{:status, ^req_ref, status}, {:headers, ^req_ref, resp_headers}, {:done, ^req_ref}] =
           resps,
         {:ok, con, ws} <- WebSocket.new(con, req_ref, status, resp_headers) do
      {:ok, con} = HTTP.controlling_process(con, controlling_pid)
      {:ok, con} = HTTP.set_mode(con, :active)

      w = %Open{con: con, ws: ws, ws_ref: req_ref, ponged: true}
      {:ok, w}
    else
      {:error, reason} ->
        {:error, %Closed{}, reason}

      {:error, con, reason} ->
        {:ok, _con} = HTTP.close(con)
        {:error, %Closed{}, reason}

      {:error, con, reason, resps} ->
        {:ok, _con} = HTTP.close(con)
        {:error, %Closed{}, {reason, resps}}

      {:ok, con, resps, unexpected_resps} ->
        {:ok, _con} = HTTP.close(con)
        {:error, %Closed{}, {:unexpected_resps, resps ++ unexpected_resps}}
    end
  end

  defguardp is_receivable(w) when is_struct(w, Open) or is_struct(w, Closing)

  # Process a received message into data frames.
  # Send pongs, set ponged, close, or fail as needed.

  @spec recv_msg(Open.t(), term) ::
          {[data_frame()], {:ok, Open.t()}}
          | {[data_frame()], {{:sent_close, close_reason}, Closing.t()}}
          | {[data_frame()], {{:closed, close_reason}, Closed.t()}}
          | {[data_frame()], {{:closed, close_reason}, Closed.t()}}
          | :unknown
  @spec recv_msg(Closing.t(), term) ::
          {[data_frame()], {:ok, Closing.t()}}
          | {[data_frame()], {{:closed, close_reason}, Closed.t()}}
          | {[data_frame()], {{:closed, close_reason}, Closed.t()}}
          | :unknown

  def recv_msg(w, msg) when is_struct(w, Open) or is_struct(w, Closing) do
    case WebSocket.stream(w.con, msg) do
      {:ok, con, resps} ->
        process_resps(resps, {:ok, %{w | con: con}})

      {:error, con, reason, resps} ->
        cd =
          case %{w | con: con} do
            %Open{} = o -> Open.fail(o)
            %Closing{} = cg -> Closing.fail(cg)
          end

        process_resps(resps, {{:failed, reason}, cd})

      :unknown ->
        :unknown
    end
    |> case do
      :unknown ->
        :unknown

      {dfs, {status, w}} ->
        state =
          if (is_struct(w, Open) or is_struct(w, Closing)) and not HTTP.open?(w.con, :read) do
            case {status, w} do
              {:ok, %Open{}} ->
                {{:failed, :closed}, Open.fail(w)}

              {:ok, %Closing{remote_close_reason: nil}} ->
                {{:failed, :closed}, Closing.fail(w)}

              {:ok, %Closing{remote_close_reason: rcr}} ->
                {{:closed, rcr}, Closing.fail(w)}

              {_, %Closed{}} ->
                {status, w}

              {{:sent_close, reason}, %Closing{remote_close_reason: nil}} ->
                {{:failed, reason}, Closing.fail(w)}
            end
          else
            {status, w}
          end

        {dfs, state}
    end
  end

  defp fail_open_or_closing(%Open{} = o), do: Open.fail(o)
  defp fail_open_or_closing(%Closing{} = cg), do: Closing.fail(cg)

  def process_resps([], state), do: {[], state}

  def process_resps([{:data, ws_ref, data} | rest], {status, %{ws_ref: ws_ref, ws: ws} = w}) do
    case WebSocket.decode(ws, data) do
      {:ok, ws, frame_results} ->
        w = %{w | ws: ws}
        {frames, state} = process_frames(frame_results, {status, w})
        {add_frames, state} = process_resps(rest, state)
        {frames ++ add_frames, state}

      {:error, ws, reason} ->
        w = %{w | ws: ws}
        cd = fail_open_or_closing(w)
        {[], {:failed, cd, reason}}
    end
  end

  # state is closed
  def process_resps([{:data, _ws_ref, _data} | _rest], state) do
    {[], state}
  end

  def process_frames([], state), do: {[], state}

  def process_frames([{data_type, data} | rest], state) when data_type in [:text, :binary] do
    {frames, state} = process_frames(rest, state)
    {[{data_type, data} | frames], state}
  end

  def process_frames([{:ping, _} | rest], {status, w}) do
    if (is_struct(w, Open) or is_struct(w, Closing)) and HTTP.open?(w.con, :write) do
      case send_pong(w.con, w.ws, w.ws_ref) do
        {:ok, con, ws} ->
          state = {status, %{w | con: con, ws: ws}}
          process_frames(rest, state)

        {:error, con, ws, reason} ->
          cd = %{w | con: con, ws: ws} |> fail_open_or_closing()
          state = {{:failed, reason}, cd}
          process_frames(rest, state)
      end
    else
      process_frames(rest, {status, w})
    end
  end

  def process_frames([{:pong, _} | rest], {status, %Open{ponged: false} = w}) do
    w = %Open{w | ponged: true}
    process_frames(rest, {status, w})
  end

  def process_frames([{:pong, _} | rest], state) do
    process_frames(rest, state)
  end

  def process_frames([{:close, code, reason} | rest], {:ok, %Open{} = o}) do
    case send_close(o.con, o.ws, o.ws_ref, %{code: code}) do
      {:ok, con, ws} ->
        cg = Closing.new(%{o | con: con, ws: ws})
        status = {:closing, {:remote_close, %{code: code, reason: reason}}}
        process_frames(rest, {status, cg})

      {:error, con, ws, reason} ->
        cd = fail_open_or_closing(%{o | con: con, ws: ws})
        status = {:failed, [{:remote_close, %{code: code, reason: reason}}, reason]}
        process_frames(rest, {status, cd})
    end
  end

  def process_frames(
        [{:close, code, reason} | rest],
        {{:sent_close, _} = status, %Closing{} = cg}
      ) do
    # They sent close before we sent our close

    cg = %Closing{cg | remote_close_reason: %{code: code, reason: reason}}
    process_frames(rest, {status, cg})
  end

  @spec send_data(Open.t(), data_frame()) :: {:ok, Open.t()} | {:failed, Closed.t(), term}
  def send_data(%Open{} = o, data_frame) do
    {:ok, ws, bin} = WebSocket.encode(o.ws, data_frame)

    case WebSocket.stream_request_body(o.con, o.ws_ref, bin) do
      {:ok, con} ->
        {:ok, %Open{o | ws: ws, con: con}}

      {:error, con, reason} ->
        {:failed, Open.fail(%{o | con: con, ws: ws}), reason}
    end
  end

  # Either send a close code, or fail if can't
  def close_local(%{ws: ws, con: con, ws_ref: ws_ref} = w, close_reason) when is_receivable(w) do
    {:ok, ws, frame_bin} =
      WebSocket.encode(ws, {:close, close_reason[:code], close_reason[:reason]})

    case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
      {:ok, con} ->
        Closing.new(%{w | con: con, ws: ws})

      {:error, con, _reason} ->
        case %{w | con: con, ws: ws} do
          %Open{} = o -> Open.fail(o)
          %Closing{} = c -> Closing.fail(c)
        end
    end
  end

  def send_pong(con, ws, ws_ref) do
    case WebSocket.encode(ws, :pong) do
      {:ok, ws, frame_bin} ->
        case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
          {:ok, con} -> {:ok, con, ws}
          {:error, con, reason} -> {:error, con, ws, reason}
        end

      {:error, ws, reason} ->
        {:error, con, ws, reason}
    end
  end

  def send_close(con, ws, ws_ref, code_reason) do
    case WebSocket.encode(ws, {:close, code_reason[:code], code_reason[:reason]}) do
      {:ok, ws, frame_bin} ->
        case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
          {:ok, con} -> {:ok, con, ws}
          {:error, con, reason} -> {:error, con, ws, reason}
        end

      {:error, ws, reason} ->
        {:error, con, ws, reason}
    end
  end

  # def send_pong(%Open{ws: ws, con: con, ws_ref: ws_ref} = w) do
  #   {:ok, ws, frame_bin} =
  #     WebSocket.encode(ws, :pong)

  #   case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
  #     {:ok, con} ->
  #       {:ok, %{w | con: con, ws: ws}}

  #     {:error, con, reason} ->
  #       {:error, fail_local(%{w | con: con, ws: ws}), reason}
  #   end
  # end

  def send_pong(%Closing{ws: ws, con: con, ws_ref: ws_ref} = w) do
    {:ok, ws, frame_bin} =
      WebSocket.encode(ws, :pong)

    case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
      {:ok, con} ->
        {:ok, %{w | con: con, ws: ws}}

      # It might be possible the connection has become read-only.
      {:error, con, _reason} ->
        {:ok, %{w | con: con, ws: ws}}
    end
  end

  def send_ping(%Open{ws: ws, con: con, ws_ref: ws_ref} = w) when is_receivable(w) do
    {:ok, ws, frame_bin} =
      WebSocket.encode(ws, :pong)

    case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
      {:ok, con} ->
        {:ok, %{w | con: con, ws: ws}}

      {:error, con, reason} ->
        {:error, fail_local(%{w | con: con, ws: ws}), reason}
    end
  end

  def fail_local(%{con: con} = w) do
    {:ok, _con} = HTTP.close(con)

    if w[:ping_timer] do
      _ = Process.cancel_timer(w.ping_timer, async: true)
    end

    %Closed{}
  end

  def remote_closed(%Open{ws: ws, con: con, ws_ref: ws_ref} = o, close_reason) do
    {:ok, ws, frame_bin} =
      WebSocket.encode(ws, {:close, close_reason[:code], close_reason[:reason]})

    w = %{o | ws: ws}

    case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
      {:ok, con} ->
        Closing.new(%{w | con: con})

      {:error, con, _reason} ->
        Open.fail(%{w | con: con})
    end
  end

  def remote_closed(%Closing{ws: ws, con: con, ws_ref: ws_ref} = o, close_reason) do
    {:ok, ws, frame_bin} =
      WebSocket.encode(ws, {:close, close_reason[:code], close_reason[:reason]})

    w = %{o | ws: ws}

    case WebSocket.stream_request_body(con, ws_ref, frame_bin) do
      {:ok, con} ->
        Closing.new(%{w | con: con})

      {:error, con, _reason} ->
        Closing.fail(%{w | con: con})
    end
  end

  # Receives status, headers, and done responses of a request.
  # Returns those responses, and out-of-order and additional responses
  # as well.
  @spec receive_resp(con, Mint.Types.request_ref()) ::
          {:ok, con, [Mint.Types.response()], other_resps :: [Mint.Types.response()]}
          | {:error, con, Mint.Types.error(), [Mint.Types.response()]}

  defp receive_resp(con, req_ref, prev_resps \\ [], timeout \\ 15_000) do
    start = System.monotonic_time(:millisecond)

    case HTTP.recv(con, 0, timeout) do
      {:ok, con, resps} ->
        case find_resp(:status, {[], prev_resps ++ resps}, req_ref) do
          {[_status, _header, _done] = resps, other_resps} ->
            {:ok, con, resps, other_resps ++ prev_resps}

          {current, other_resps} ->
            stop = System.monotonic_time(:millisecond)
            timeout = (timeout - (stop - start)) |> max(0)
            receive_resp(con, req_ref, other_resps ++ other_resps ++ current, timeout)
        end

      {:error, con, reason, resps} ->
        {:error, con, reason, prev_resps ++ resps}
    end
  end

  defp find_resp(_, {other, []}, _req_ref), do: {other, []}

  defp find_resp(
         :status,
         {other, [{:status, req_ref, _status} = resp | rest]},
         req_ref
       ) do
    {header_done, other_other} = find_resp(:headers, {other, rest}, req_ref)
    {[resp | header_done], other_other}
  end

  defp find_resp(
         :headers,
         {other, [{:headers, req_ref, _} = resp | rest]},
         req_ref
       ) do
    {done, other_other} = find_resp(:done, {other, rest}, req_ref)
    {[resp | done], other_other}
  end

  defp find_resp(
         :done,
         {other, [{:done, req_ref} = resp | rest]},
         req_ref
       ) do
    {[resp], other ++ rest}
  end

  defp find_resp(type, {other, [resp | rest]}, req_ref) when elem(resp, 1) !== req_ref do
    find_resp(type, {other ++ [resp], rest}, req_ref)
  end
end
