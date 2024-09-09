defmodule Wesex do
  @moduledoc """
  Behaviour for a process that handles websocket communication as the client.

  Doing `use Wesex` adds `@behaviour Wesex` and defines a `child_spec` function
  """
  alias __MODULE__.Websocket
  require Websocket

  use GenServer

  @typedoc """
  A websocket structure.
  """
  @type websocket ::
          Websocket.closed() | Websocket.opening() | Websocket.open() | Websocket.closing()

  @doc """
  Genserver-like init callback.

  If the third element in the return tuple is in the form
  `{:open, {URI.t(), Websocket.headers()}`, then a websocket connection
  is opened.
  """
  @callback init(any) ::
              {:ok, state :: any()}
              | {:ok, state :: any, {:open, {URI.t(), Websocket.headers()}}}
              | {:ok, state :: any, {:continue, any}}
              | :ignore
              | {:stop, any}

  @doc """
  Genserver-like handle_call callback.

  If the process is called with `GenServer.call/3`, then this callback
  is invoked. Arguments `state` is the state returned from the previous callback,
  `websocket` as managed by `Wesex`.

  If the `websocket` is modified eg. with `Wesex.Websocket.send/2`, then the new
  modified websocket must be returned.
  """
  @callback handle_call(req :: any, from :: GenServer.from(), state :: any, websocket()) ::
              {:reply, any, {state :: any, websocket()}}
              | {:noreply, {state :: any, websocket()}}

  @doc """
  Genserver-like callback. See `c:handle_call/4`.
  """
  @callback handle_info(any, state :: any, websocket()) ::
              {:noreply, {state :: any, websocket()}}

  @doc """
  Genserver-like callback. See `c:handle_call/4`.
  """
  @callback handle_continue(any, state :: any, websocket()) ::
              {:noreply, {state :: any, websocket()}}

  @doc """
  Called when a websocket message arrives.
  """
  @callback handle_in(Websocket.dataframe(), reference(), state :: any, websocket()) ::
              {:ok, state :: any, websocket()}

  @doc """
  Called when the websocket completes its opening handshake.
  """
  @callback handle_open(:done | {:error, any}, open_ref :: reference(), state :: any, websocket()) ::
              {:ok, state :: any, websocket()}

  @doc """
  Called when the websocket finalized its closing.
  """
  @callback handle_close(
              close_reason ::
                {:local_initiated | :remote_initiated,
                 remote_close_reason :: Websocket.close_reason()}
                | {:error, any},
              close_ref :: reference(),
              state :: any,
              websocket()
            ) ::
              {:ok, state :: any, websocket()}

  @doc """
  Optional Genserver-like callback. See `c:handle_call/4`.
  """
  @callback terminate(reason :: any, state :: any) :: any
  @optional_callbacks [terminate: 2]

  defmacro __using__(child_spec_opts) do
    quote do
      @behaviour Wesex

      def child_spec(init_arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(child_spec_opts)))
      end

      defoverridable child_spec: 1
    end
  end

  @spec start_link(%{
          optional(:adapter_opts) =>
            keyword({:con_opts, keyword()} | {:ws_opts, keyword()}) | Access.t(),
          optional(:adapter) => Wesex.Adapter.impl(),
          cb: callback_module :: module(),
          init_arg: any,
          gen_server_opts: keyword()
        }) :: GenServer.on_start()
  @doc """
  Start a `Wesex` process linked.

  Arguments:
  * `:cb` - Callback module that implements `Wesex` behaviour.
  * `:init_arg` - Given to `c:init/1`
  * `:gen_server_opts` - `t:GenServer.options/0`
  * `:adapter_opts` - (optional) Map/keywords of `:con_opts` and `:ws_opts` given to the adapter.
  * `:adapter` - (optional) A module that implements `Wesex.Adapter`, `Wesex.MintAdapter` by default.

  Traps exits after calling the `init` function.
  """
  def start_link(
        %{cb: _callback_module, init_arg: _user_arg, gen_server_opts: _gen_server_opts} = args
      ) do
    {gen_server_opts, args} = Map.pop!(args, :gen_server_opts)
    GenServer.start_link(__MODULE__, args, gen_server_opts)
  end

  @impl GenServer
  def init(arg) do
    adapter = arg[:adapter] || Wesex.MintAdapter

    case arg.cb.init(arg.user_arg) do
      {:ok, user_state} ->
        state = %{
          user_state: user_state,
          w: Websocket.new(adapter),
          adapter_opts: arg[:adapter_opts] || [],
          cb: arg.cb
        }

        true = Process.flag(:trap_exit, true)

        {:ok, state}

      {:ok, user_state, {:open, url_headers}} ->
        state = %{
          user_state: user_state,
          w: Websocket.new(adapter),
          adapter_opts: arg[:adapter_opts] || [],
          cb: arg.cb
        }

        true = Process.flag(:trap_exit, true)

        {:ok, state, {:continue, {:open, url_headers}}}

      {:ok, user_state, {:handle_continue, cont_arg}} ->
        state = %{
          user_state: user_state,
          w: Websocket.new(adapter),
          adapter_opts: arg[:adapter_opts] || [],
          cb: arg.cb
        }

        true = Process.flag(:trap_exit, true)

        {:ok, state, {:handle_continue, cont_arg}}

      :ignore ->
        :ignore

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue({:open, {url, headers}}, state) when Websocket.is_closed(state.w) do
    case Websocket.open(
           state.w,
           url,
           headers: headers,
           con_opts: state.adapter_opts[:con_opts] || [],
           ws_opts: state.adapter_opts[:ws_opts] || []
         ) do
      {:ok, w} when Websocket.is_opening(w) -> {:noreply, %{state | w: w}}
      {:error, w, reason} when Websocket.is_closed(w) -> {:stop, reason}
    end
  end

  def handle_continue(continue_arg, state) do
    case state.cb.handle_continue(continue_arg, state.user_state, state.w) do
      {:noreply, {user_state, w}} ->
        state = %{state | w: w, user_state: user_state}
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(msg, state) do
    case Websocket.stream(msg, state.w) do
      {events, w} ->
        state = %{state | w: w}
        handle_info_events(events, state)

      :unknown ->
        user_handle_info(msg, state)
    end
  end

  @impl GenServer
  def handle_call(request, from, state) do
    case state.cb.handle_call(request, from, state.user_state, state.w) do
      {:noreply, {user_state, w}} ->
        state = %{state | w: w, user_state: user_state}
        {:noreply, state}

      {:reply, reply, {user_state, w}} ->
        state = %{state | w: w, user_state: user_state}
        {:reply, reply, state}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    _ =
      if Websocket.is_open(state.w) do
        w = Websocket.close(state.w, %{code: 1001})
        _ = recv_until_closed(w)
      end

    _ =
      if function_exported?(state.cb, :terminate, 2) do
        _ = state.terminate(reason, state.user_state)
      end
  end

  defp recv_until_closed(w) do
    receive do
      msg ->
        case Websocket.stream(msg, w) do
          :unknown -> recv_until_closed(w)
          {_, w} when Websocket.is_closed(w) -> w
          {_, w} -> recv_until_closed(w)
        end
    end
  end

  defp handle_info_events([], state), do: {:noreply, state}

  defp handle_info_events([{:dataframe, ref, dataframe} | rest], state) do
    case state.cb.handle_in(dataframe, ref, state.user_state, state.w) do
      {:ok, user_state} ->
        state = put_in(state.user_state, user_state)
        handle_info_events(rest, state)
    end
  end

  defp handle_info_events([{:opening, ref, :done} | rest], state) do
    case state.cb.handle_open(:done, ref, state.user_state, state.w) do
      {:ok, user_state, w} ->
        state = %{state | w: w, user_state: user_state}
        handle_info_events(rest, state)
    end
  end

  defp handle_info_events([{:opening, ref, :error, reason} | rest], state) do
    case state.cb.handle_open({:error, reason}, ref, state.user_state, state.w) do
      {:ok, user_state, w} ->
        state = %{state | w: w, user_state: user_state}
        handle_info_events(rest, state)
    end
  end

  defp handle_info_events([{:closed, ref, initiator, reason} | rest], state) do
    case state.cb.handle_close({initiator, reason}, ref, state.user_state, state.w) do
      {:ok, user_state, w} ->
        state = %{state | w: w, user_state: user_state}
        handle_info_events(rest, state)
    end
  end

  defp user_handle_info(msg, state) do
    state.cb.handle_info(msg, state.user_state, state.w)
  end
end
