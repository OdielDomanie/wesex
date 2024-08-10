defmodule Wesex do
  alias __MODULE__.Websocket
  require Websocket

  use GenServer

  @type websocket ::
          Websocket.closed() | Websocket.opening() | Websocket.open() | Websocket.closing()

  @callback init(any) ::
              {:ok, state :: any()}
              | {:ok, state :: any, {:open, {URI.t(), Websocket.headers()}}}
              | {:ok, state :: any, {:continue, any}}
              | :ignore
              | {:stop, any}
  @callback handle_call(req :: any, from :: GenServer.from(), state :: any, websocket()) ::
              {:reply, any, {state :: any, websocket()}}
              | {:noreply, {state :: any, websocket()}}

  @callback handle_info(any, state :: any, websocket()) ::
              {:noreply, {state :: any, websocket()}}

  @callback handle_continue(any, state :: any, websocket()) ::
              {:noreply, {state :: any, websocket()}}

  @callback handle_in(Websocket.dataframe(), reference(), state :: any, websocket()) ::
              {:ok, state :: any, websocket()}

  @callback handle_open(:done | {:error, any}, reference(), state :: any, websocket()) ::
              {:ok, state :: any, websocket()}

  @callback handle_close(
              {:local_initiated | :remote_initiated,
               remote_close_reason :: Websocket.close_reason()}
              | {:error, any},
              reference(),
              state :: any,
              websocket()
            ) ::
              {:ok, state :: any, websocket()}

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
          optional(:ws_opts) =>
            keyword({:con_opts, keyword()} | {:ws_opts, keyword()}) | Access.t(),
          optional(:adapter) => Wesex.Adapter.impl(),
          cb: callback_module :: module(),
          init_arg: any,
          gen_server_opts: keyword()
        }) :: GenServer.on_start()
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
          ws_opts: arg[:ws_opts] || [],
          cb: arg.cb
        }

        {:ok, state}

      {:ok, user_state, {:open, url_headers}} ->
        state = %{
          user_state: user_state,
          w: Websocket.new(adapter),
          ws_opts: arg[:ws_opts] || [],
          cb: arg.cb
        }

        {:ok, state, {:continue, {:open, url_headers}}}

      {:ok, user_state, {:handle_continue, cont_arg}} ->
        state = %{
          user_state: user_state,
          w: Websocket.new(adapter),
          ws_opts: arg[:ws_opts] || [],
          cb: arg.cb
        }

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
           con_opts: state.ws_opts[:con_opts] || [],
           ws_opts: state.ws_opts[:ws_opts] || []
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

        # {:push, dataframe_pushes, user_state} ->
        #   state = put_in(state.user_state, user_state)
        #   {push_results, state} = push_dataframes(dataframe_pushes, state)
        #   handle_info_events(rest ++ push_results, state)
        # {:close, close_reason, dataframe_pushes, user_state} ->

        #   state = put_in(state.user_state, user_state)
        #   {push_results, state} = push_dataframes(dataframe_pushes, state)
        #   w = close_if_open(state.w, close_reason)
        #   case close(state.w, close_reason) do
        #     w when is_closing(w) ->
        #   end
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

  # defp close(w, close_reason) when is_open(w), do: Websocket.close(w, close_reason)
  # defp close(w, close_reason) when is_open(w), do: Websocket.close(w, close_reason)

  # defp push_dataframes([], state), do: {[], state}

  # defp push_dataframes([{ref, dataframe} | rest], state) when is_open(state.w) do
  #   case Websocket.send(dataframe, state.w) do
  #     {:ok, w} ->
  #       state = put_in(state.w, w)
  #       event = {:push, ref, :done}
  #       {rest_events, state} = push_dataframes(rest, state)
  #       {[event | rest_events], state}

  #     {:error, w, reason} ->
  #       state = put_in(state.w, w)
  #       event = {:push, ref, :error, reason}
  #       {rest_events, state} = push_dataframes(rest, state)
  #       {[event | rest_events], state}
  #   end
  # end

  # defp push_dataframes([{ref, _dataframe} | rest], state) when not is_open(state.w) do
  #   event = {:push, ref, :error, :closed}
  #   {rest_events, state} = push_dataframes(rest, state)
  #   {[event | rest_events], state}
  # end
end
