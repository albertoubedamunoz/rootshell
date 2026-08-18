# MCP Server Integration

The Model Context Protocol (MCP) server in Rootshell allows AI tools like Claude Code, Codex CLI, and Gemini CLI to execute SSH commands and access cloud/Kubernetes resources on your iOS device.

## Quick Start

1. **Enable the MCP Server**: Go to Settings → MCP Server → Enable MCP Server
2. **Note the port number** displayed in settings
3. **Configure your AI tool** (see examples below)
4. **Approve the connection** when prompted in the app

## Connection Methods

### Local Connection (Same Device)
If running an AI tool on the same device or Mac via Handoff:
```
localhost:{port}
```

### SSH Port Forwarding (Remote)
To access the MCP server from a remote machine:

```bash
# From the machine running Claude Code/Codex:
ssh -R 9000:localhost:{mcp-port} user@your-ipad-hostname

# Now AI tools on that machine can connect to localhost:9000
```

Replace `{mcp-port}` with the port shown in MCP Settings.

## AI Tool Configuration

### Claude Code

Add the MCP server using the CLI:

```bash
claude mcp add rootshell -- nc localhost {PORT}
```

Replace `{PORT}` with the port shown in Settings → MCP Server.

When Claude Code first connects, you'll see an approval prompt in the app. Tap "Allow" to authorize the connection.

### Codex CLI

Edit `~/.codex/config.toml`:

```toml
[mcp_servers.rootshell]
command = "nc"
args = ["localhost", "{PORT}"]
```

### Gemini CLI

Edit `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "rootshell": {
      "command": "nc",
      "args": ["localhost", "{PORT}"]
    }
  }
}
```

## Available Tools

### ssh_execute
Execute a command on a remote host via SSH.

**Parameters:**
- `host` (required): Hostname or IP address to connect to
- `command` (required): Command to execute
- `user` (optional): SSH username (default: uses history or current user)
- `port` (optional): SSH port (default: 22)
- `timeout` (optional): Command timeout in seconds (default: 60)

**Example:**
```json
{
  "tool": "ssh_execute",
  "params": {
    "host": "server.example.com",
    "command": "uptime",
    "user": "admin"
  }
}
```

**Returns:**
```json
{
  "exitCode": 0,
  "stdout": " 14:32:01 up 45 days...",
  "stderr": "",
  "durationMs": 1234
}
```

### ssh_list_hosts
List known SSH hosts from connection history.

**Parameters:**
- `filter` (optional): Filter hosts by name/address
- `limit` (optional): Maximum hosts to return (default: 20)

**Example:**
```json
{
  "tool": "ssh_list_hosts",
  "params": {
    "filter": "prod",
    "limit": 10
  }
}
```

**Returns:**
```json
{
  "hosts": [
    {
      "display": "admin@prod-server1.example.com",
      "host": "prod-server1.example.com",
      "username": "admin",
      "port": 22,
      "hasJumpHost": false,
      "lastUsed": "2025-01-15T10:30:00Z"
    }
  ]
}
```

### ssh_get_host_info
Get detailed information about a specific SSH host.

**Parameters:**
- `host` (required): Hostname to look up

**Returns:**
```json
{
  "host": "server.example.com",
  "port": 22,
  "username": "admin",
  "authMethod": "publickey",
  "hasJumpHost": true,
  "jumpHost": "bastion.example.com",
  "lastUsed": "2025-01-15T10:30:00Z"
}
```

## Available Resources

### Cloud Instances
URI scheme: `cloud://instances/{provider}/{instance-id}`

Lists and provides details about cloud VMs from connected providers (AWS, Azure, DigitalOcean, Linode).

**Example resource:**
```json
{
  "uri": "cloud://instances/linode/12345678",
  "name": "web-server-1",
  "description": "[running] linode - us-east",
  "mimeType": "application/json"
}
```

### Kubernetes Clusters
URI scheme: `k8s://cloud/{provider}/{cluster-id}` or `k8s://local/{uuid}`

Lists and provides details about Kubernetes clusters (both cloud-managed and locally imported).

**Example resource:**
```json
{
  "uri": "k8s://cloud/digitalocean/abc123",
  "name": "production-cluster",
  "description": "[running] digitalocean K8s v1.28",
  "mimeType": "application/json"
}
```

## Security Modes

Configure the security mode in Settings → MCP Server → Session Mode:

| Mode | Description |
|------|-------------|
| **Standard** | Safe operations auto-approve. Dangerous operations (ssh_execute) require approval. |
| **Cautious** | All operations require explicit approval. |
| **YOLO** | All operations auto-approve. **Use with extreme caution.** |

### Operation Risk Levels

- **Safe**: `ssh_list_hosts`, `ssh_get_host_info`, `tools/list`, `resources/list`, `resources/read`
- **Dangerous**: `ssh_execute` (command execution)

## Authentication

The MCP server uses **connection approval** for authentication. When a new AI tool connects:

1. The app displays an approval prompt showing the client name and version
2. Tap "Allow" to authorize the connection for the session
3. Tap "Deny" to reject the connection

This approach:
- Works with all AI tools without special configuration
- Provides clear visibility into what's connecting
- Doesn't require copying/pasting tokens

Once approved, the connection remains active for the entire AI tool session.

## Protocol Details

The MCP server implements the [Model Context Protocol](https://modelcontextprotocol.io/) over JSON-RPC 2.0.

- **Transport**: TCP with newline-delimited JSON (JSONL)
- **Protocol Version**: 2024-11-05
- **Supported Methods**:
  - `initialize` / `initialized`
  - `tools/list` / `tools/call`
  - `resources/list` / `resources/read`

## Troubleshooting

### Connection Refused
- Ensure the MCP server is enabled in Settings
- Check the port number matches your configuration
- Verify SSH port forwarding is active (for remote connections)

### Authentication Failed
- Verify the token matches the one shown in Settings
- Regenerate the token if needed
- Ensure the token is passed in the `initialize` request

### Approval Timeout
- Approvals timeout after 30 seconds if not responded to
- Keep the app in foreground for faster approval
- Enable notifications for background approval prompts

### SSH Command Fails
- Verify SSH keys are configured in Settings → SSH Keys
- Check the host is reachable from your iOS device
- For jump hosts, ensure both keys are available
