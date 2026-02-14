c = get_config()

# Keep server and kernels alive indefinitely
c.ServerApp.shutdown_no_activity_timeout = 0
c.MappingKernelManager.cull_idle_timeout = 0
c.MappingKernelManager.cull_interval = 0
c.MappingKernelManager.cull_connected = False
c.MappingKernelManager.cull_busy = False

# High IOPub limits (Jupyter Server 2.x)
c.ZMQChannelsWebsocketConnection.iopub_msg_rate_limit = 1.0e12
c.ZMQChannelsWebsocketConnection.rate_limit_window = 1.0

# WebSocket keepalives
c.ServerApp.websocket_ping_interval = 30000   # ms
c.ServerApp.websocket_ping_timeout  = 30000   # ms
c.ZMQChannelsWebsocketConnection.websocket_ping_interval = 30000
c.ZMQChannelsWebsocketConnection.websocket_ping_timeout  = 30000
c.TerminalsWebsocketConnection.websocket_ping_interval = 30000
c.TerminalsWebsocketConnection.websocket_ping_timeout  = 30000

# Token provided via env; entrypoint exports JUPYTER_TOKEN
import os
c.IdentityProvider.token = os.environ.get("JUPYTER_TOKEN", "")

