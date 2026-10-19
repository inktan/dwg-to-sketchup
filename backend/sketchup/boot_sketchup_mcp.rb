# Load the installed sketchup-mcp extension and start its TCP server.
begin
  load 'C:/set/dwg-to-sketchup/backend/sketchup/su_mcp/main.rb'
  server = SU_MCP.instance_variable_get(:@server)
  raise 'sketchup-mcp server object missing' if server.nil?
  server.start
  File.write('C:/set/dwg-to-sketchup/backend/sketchup-mcp-status.txt', "listening #{Time.now}\n")
  'listening'
rescue => e
  File.write('C:/set/dwg-to-sketchup/backend/sketchup-mcp-status.txt', "error #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}\n")
  raise
end
