defmodule Wesex.Connection do
  @moduledoc """
  Manages a websocket connection by functionally manipulating a connection struct.

  The functions may set up timers, whose messages should  be received
  and given to `event/2`.

  ## State diagram
  ```mermaid
  stateDiagram-v2
  [*] --> handshaking: connect/4
  handshaking --> closed: handshake timeout
  handshaking --> open
  open --> closing: ping timeout
  open --> closing: remote close
  open --> closing: close/3
  handshaking --> closing: close/3
  handshaking --> closed: tcp close
  open --> closed: tcp close
  closing --> closed: tcp close
  closing --> closed: close timeout
  ```
  """

  alias Wesex.MintAdapter
  alias __MODULE__, as: C
  @type adapter :: module()

  @typedoc """
  Connection struct.
  """
  @type t :: %__MODULE__{
          status:
            :handshaking
            | {:open, :ponged | :unponged}
            | :local_closing
            | :waiting_tcp_close
            | :closed,
          adapter: module(),
          adapter_state: any(),
          timer: {reference(), timer_type()} | nil,
          ref: reference(),
          remote_stop_code_reason: nil | stop_code_reason(),
          ping_timeout: :close | (-> any())
        }

  @type input_event :: adapter_event | {reference, :wesex_timer, timer_type}

  # * `{:sent, reference} — The message was sent successfully. (see `send/3`)
  # * `{:send_error, reference, reason}` —
  #       The message could not be sent successfully. (see `send/3`)
  @typedoc """
  Results from the functions in this module.
  * `:open` — The handshake is complete and the connection is open.
  * `{:received, msg}` — Message received.
  * `{:closing, reason}` — The connection is closing.
        If it closing handshake is local initiated,
        the stop code & reason is the one the client has sent.
        If it is remote initiated, it stop code & reason is what the
        server has sent.
  * `{:closed, reason}` — The TCP connection is closed.
        If the closing handshake was successful,
        the reason is `{:remote, stop_code_reason()}`
        If the connection is closed without a complete closing handshake,
        it will be `{:error, reason}`. In that case `{:closing, _}` event
        may never be emitted.
  """
  @type result_event ::
          :open
          | {:received, {:text | :binary, binary()}}
          # | {:sent, term()}
          # | {:send_error, term(), reason :: any}
          | {:closing, {:local, stop_code_reason()} | {:remote, stop_code_reason()}}
          | {:closed,
             {:remote, stop_code_reason()}
             | {:error, :timeout | :aborted | :closed_in_handshake | :unexpected_tcp_close}}

  @type adapter_event :: term()
  # :handshake_complete
  # | {:ping | :pong, nil | binary()}
  # | {:text | :binary, binary()}
  # | {:close, 1000..4999 | nil, binary() | nil}
  # | :tcp_close

  @type stop_code_reason :: {1000..4999 | nil, binary() | nil}
  @type timer_type :: :handshake_timeout | :ping_timer | :close_timeout

  @enforce_keys [:status, :adapter, :adapter_state, :ref]
  defstruct [
    :status,
    :adapter,
    :adapter_state,
    :timer,
    :ref,
    :remote_stop_code_reason,
    ping_timeout: :close
  ]

  @handshake_timeout 4_000
  @close_timeout 4_000
  @ping_intv 10_000

  @doc """
  Starts a websocket connection.

  Returns a connection in the handshaking stage.
  Returns the error from `adapter.connect/3` as is.
  """
  @spec connect(URI.t() | String.t(), [{String.t(), String.t()}], adapter(), keyword()) ::
          {:ok, t} | {:error, term}
  def connect(url, headers \\ [], adapter \\ MintAdapter, adapter_opts \\ []) do
    do_connect(url, headers, adapter, adapter_opts)
  end

  @doc """
  Takes adapter's events, modifying the state and outputting result events.

  Returns false if the event does not belong to this connection.
  """
  @spec event(t, input_event) :: {[result_event], t} | false
  def event(connection, input_event) do
    do_event(connection, input_event)
  end

  @doc """
  Sends a message.

  The returned error reason is from `adapter.send/2`.
  """
  @spec send(t, {:text | :binary, String.t()}) :: {:ok | {:error, term()}, [result_event], t}
  def send(conn, message) do
    do_send(conn, message)
  end

  # @doc """
  # Tries sending a message.

  # Any term can be given as a reference for the message.
  # A result event of `{:sent, reference}` or `{:send_error, reference, reason}`
  # will be emitted as a result of this function or from a future function call that
  # returns result events, with the `reference` as the same value givent to this function.
  # """
  # @spec send(t, {:text | :binary, binary()}, term()) :: {[result_event], t}
  # def send(conn, message, reference \\ make_ref()) do
  #   do_send(conn, message, reference)
  # end

  @doc """
  Starts the closing handshake.

  This function has no effect if the connection is already
  in a closing or closed state. If the connection is in handshaking state,
  it is aborted instead (no closing handshake is sent).
  """
  @spec close(t, stop_code_reason()) :: {[result_event()], t}
  def close(conn, code_reason) do
    do_close(conn, code_reason)
  end

  @doc """
  Closes the TCP connection without handshake.
  """
  @spec abort(t) :: {[result_event()], t}
  def abort(conn) do
    do_abort(conn)
  end

  @doc """
  Short status of the connection.
  """
  @spec status(t) :: :handshaking | :open | :closing | :closed
  def status(%C{status: status} = _conn) do
    case status do
      :handshaking -> :handshaking
      {:open, _} -> :open
      :local_closing -> :closing
      :waiting_tcp_close -> :closing
      :closed -> :closed
    end
  end

  # Inline to simplify stack trace bc. we use the header pattern.
  @compile {:inline, do_connect: 4, do_event: 2, do_close: 2}

  defp do_connect(url, headers, adapter, adapter_opts) do
    uri = URI.new!(url)

    case adapter.connect(uri, headers, adapter_opts) do
      {:ok, adapter_state} ->
        ref = make_ref()
        handshake_timeout = timer(ref, :handshake_timeout, @handshake_timeout)

        conn = %C{
          adapter: adapter,
          adapter_state: adapter_state,
          ref: ref,
          status: :handshaking,
          timer: {:handshake_timeout, handshake_timeout}
        }

        {:ok, conn}

      {:error, r} ->
        {:error, r}
    end
  end

  defp do_event(%C{status: :closed}, _), do: false

  defp do_event(%C{ref: ref, status: status} = c, {ref, :wesex_timer, timer_type}) do
    case {status, timer_type} do
      {:handshaking, :handshake_timeout} ->
        {[:tcp_close], adapter_state} = c.adapter.abort(c.adapter_state)
        c = %{c | adapter_state: adapter_state, status: :closed, timer: nil}
        {[closed: {:error, :closed_in_handshake}], c}

      {{:open, :ponged}, :ping_timer} ->
        {adp_results, adp_state} = c.adapter.send_ping(c.adapter_state)
        timer = timer(c.ref, :ping_timer, @ping_intv)

        c = %{
          c
          | adapter_state: adp_state,
            status: {:open, :unponged},
            timer: {:ping_timer, timer}
        }

        do_adapter_results(c, adp_results)

      {{:open, :unponged}, :ping_timer} when c.ping_timeout == :close ->
        # 1002: protocol error
        {adp_results, adp_state} = c.adapter.local_close({1002, "ping timeout"}, c.adapter_state)
        timer = timer(c.ref, :close_timeout, @close_timeout)

        c = %{
          c
          | status: :local_closing,
            adapter_state: adp_state,
            timer: {:close_timeout, timer}
        }

        {results, c} = do_adapter_results(c, adp_results)
        {[{:closing, {:local, {1002, "ping timeout"}}} | results], c}

      {{:open, :unponged}, :ping_timer} when is_function(c.ping_timeout) ->
        c.ping_timeout.()

        {adp_results, adp_state} = c.adapter.send_ping(c.adapter_state)
        timer = timer(c.ref, :ping_timer, @ping_intv)

        c = %{
          c
          | adapter_state: adp_state,
            status: {:open, :unponged},
            timer: {:ping_timer, timer}
        }

        do_adapter_results(c, adp_results)

      {status, :close_timeout} when status in [:local_closing, :waiting_tcp_close] ->
        {[:tcp_close], adp_state} = c.adapter.abort(c.adapter_state)
        c = %{c | status: :closed, adapter_state: adp_state, timer: nil}
        {[closed: {:error, :timeout}], c}
    end
  end

  defp do_event(%C{} = c, input_event) do
    case c.adapter.event(input_event, c.adapter_state) do
      {adapter_results, adapter_state} ->
        c = %{c | adapter_state: adapter_state}
        do_adapter_results(c, adapter_results)

      false ->
        false
    end
  end

  defguardp is_msg_type(type) when type in [:text, :binary]

  defp do_send(%C{} = c, msg) do
    case c.adapter.send(msg, c.adapter_state) do
      {:ok, adp_results, adp_state} ->
        c = %{c | adapter_state: adp_state}
        {results, c} = do_adapter_results(c, adp_results)
        {:ok, results, c}

      {:error, adp_results, adp_state, reason} ->
        c = %{c | adapter_state: adp_state}
        {results, c} = do_adapter_results(c, adp_results)
        {{:error, reason}, results, c}
    end
  end

  defp do_close(%C{status: {:open, _}} = c, code_reason) do
    cancel_timer(c.timer)
    {adp_results, adp_state} = c.adapter.local_close(code_reason, c.adapter_state)
    timer = timer(c.ref, :close_timeout, @close_timeout)
    c = %{c | adapter_state: adp_state, status: :local_closing, timer: {:close_timeout, timer}}
    {next_results, c} = do_adapter_results(c, adp_results)
    {[{:closing, {:local, code_reason}} | next_results], c}
  end

  defp do_close(%C{status: status} = c, _code_reason)
       when status == :local_closing
       when status == :waiting_tcp_close
       when status == :closed do
    {[], c}
  end

  defp do_close(%C{status: :handshaking} = c, _code_reason) do
    do_abort(c)
  end

  defp do_abort(%C{} = c) do
    c.timer && cancel_timer(c.timer)
    {adp_results, adp_state} = c.adapter.abort(c.adapter_state)
    c = %{c | adapter_state: adp_state, timer: nil}
    do_adapter_results(c, adp_results)
  end

  defp do_adapter_results(%C{} = c, []) do
    {[], c}
  end

  defp do_adapter_results(%C{status: :handshaking} = c, [:handshake_complete | rest]) do
    cancel_timer(c.timer)
    ping_timer = timer(c.ref, :ping_timer, 0)
    c = %{c | status: {:open, :ponged}, timer: {:ping_timer, ping_timer}}
    {results_rest, c} = do_adapter_results(c, rest)
    {[:open | results_rest], c}
  end

  # receive message
  defp do_adapter_results(%C{status: {:open, _}} = c, [{type, _data} = msg | rest])
       when is_msg_type(type) do
    {next_results, c} = do_adapter_results(c, rest)
    {[{:received, msg} | next_results], c}
  end

  defp do_adapter_results(%C{status: :local_closing} = c, [{type, _data} = msg | rest])
       when is_msg_type(type) do
    {next_results, c} = do_adapter_results(c, rest)
    {[{:received, msg} | next_results], c}
  end

  # # message confirmation
  # defp do_adapter_results(%C{} = c, [{:sent, ref} | rest]) do
  #   {next_results, c} = do_adapter_results(c, rest)
  #   {[{:sent, ref} | next_results], c}
  # end

  # defp do_adapter_results(%C{} = c, [{:send_error, ref, reason} | rest]) do
  #   {next_results, c} = do_adapter_results(c, rest)
  #   {[{:send_error, ref, reason} | next_results], c}
  # end

  # get pinged
  defp do_adapter_results(%C{status: {:open, _}} = c, [{:ping, ping_data} | rest]) do
    {adp_results_new, adp_state} = c.adapter.send_pong(ping_data, c.adapter_state)
    c = %{c | adapter_state: adp_state}
    do_adapter_results(c, rest ++ adp_results_new)
  end

  defp do_adapter_results(%C{status: :local_closing} = c, [{:ping, _ping_data} | rest]) do
    do_adapter_results(c, rest)
  end

  # get ponged
  defp do_adapter_results(%C{status: {:open, :unponged}} = c, [{:pong, _} | rest]) do
    c = %{c | status: {:open, :ponged}}
    do_adapter_results(c, rest)
  end

  defp do_adapter_results(%C{status: {:open, :ponged}} = c, [{:pong, _} | rest]) do
    do_adapter_results(c, rest)
  end

  defp do_adapter_results(%C{status: :local_closing} = c, [{:pong, _} | rest]) do
    do_adapter_results(c, rest)
  end

  # close response
  defp do_adapter_results(%C{status: :local_closing} = c, [{:close, code, reason} | rest]) do
    c = %{c | status: :waiting_tcp_close, remote_stop_code_reason: {code, reason}}
    do_adapter_results(c, rest)
  end

  # remote close
  defp do_adapter_results(%C{status: {:open, _}} = c, [{:close, code, reason} | rest]) do
    {adp_results_new, adp_state} = c.adapter.local_close({code, nil}, c.adapter_state)
    cancel_timer(c.timer)
    close_timeout = timer(c.ref, :close_timeout, @close_timeout)

    c = %{
      c
      | status: :waiting_tcp_close,
        remote_stop_code_reason: {code, reason},
        adapter_state: adp_state,
        timer: {:close_timeout, close_timeout}
    }

    {next_results, c} = do_adapter_results(c, rest ++ adp_results_new)
    {[{:closing, {:remote, {code, reason}}} | next_results], c}
  end

  # tcp close
  defp do_adapter_results(%C{status: :waiting_tcp_close} = c, [:tcp_close | rest]) do
    cancel_timer(c.timer)
    c = %{c | status: :closed, timer: nil}

    {next_results, c} = do_adapter_results(c, rest)
    {[{:closed, {:remote, c.remote_stop_code_reason}} | next_results], c}
  end

  # unexpected tcp close
  defp do_adapter_results(%C{} = c, [:tcp_close | rest])
       when c.status == :handshaking
       when elem(c.status, 0) == :open
       when c.status == :local_closing do
    cancel_timer(c.timer)

    c = %{c | status: :closed, timer: nil}

    {next_results, c} = do_adapter_results(c, rest)
    {[{:closed, {:error, :unexpected_tcp_close}} | next_results], c}
  end

  defp timer(ref, type, time) do
    Process.send_after(self(), {ref, :wesex_timer, type}, time)
  end

  defp cancel_timer({timer_type, timer}) do
    Process.cancel_timer(timer)

    receive do
      ^timer_type -> :ok
    after
      0 -> :ok
    end
  end
end
