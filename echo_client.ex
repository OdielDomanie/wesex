defmodule  do
  alias Wesex.Connection
  use Wesex
  @behaviour Connection

  def start_link(opts) do
    {wesex_opts, genserver_opts} = Keyword.split(opts, [:url, :headers, :adapter_opts, :init_arg ])
    GenServer.start_link(__MODULE__, wesex_opts, genserver_opts)
  end

  @impl GenServer
  def init(init_arg) do
    super([{:callbacks, __MODULE__} | init_arg])
  end

  @impl Connection
  def handle_connected(state) do
    {:ok, state, []}
  end

  @impl Connection
  def handle_message({type, data}, state, _status) do
    {:ok, state, [{type, data}]}
  end

  # @impl GenServer
  # def handle_call()

  # @impl true
  # def handle_other_info

end
