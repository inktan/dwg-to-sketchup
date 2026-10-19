# Load the SketchUp MCP extension next to this file and start its TCP server.
begin
  here = File.dirname(__FILE__)
  load File.expand_path('su_mcp/main.rb', here)
  server = SU_MCP.instance_variable_get(:@server)
  raise 'sketchup-mcp server object missing' if server.nil?
  server.start
  status = File.expand_path('../sketchup-mcp-status.txt', __FILE__)
  File.write(status, "listening #{Time.now}\n")
  'listening'
rescue => e
  status = File.expand_path('../sketchup-mcp-status.txt', __FILE__)
  File.write(status, "error #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}\n")
  raise
end
