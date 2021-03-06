package com.rabbitmq.streams.plugins.socket.source;
import com.rabbitmq.streams.harness.Server;
import net.sf.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;


public class SocketSourceServer extends Server {

  private final Map<String, List<SocketSource>> terminalMap = new HashMap<String, List<SocketSource>>();

  protected void terminalStatusChange(String terminalId, List<JSONObject> terminalConfigurations, boolean active) {
    if (active) {
      List<SocketSource> sources = terminalMap.get(terminalId);
      if (null == sources || 0 == sources.size()) {
        sources = new ArrayList<SocketSource>(terminalConfigurations.size());
        for (JSONObject terminal : terminalConfigurations) {
          JSONObject sourceConfig = terminal.getJSONObject("source");
          SocketSource source = new SocketSource(sourceConfig, terminalId);
          sources.add(source);
          Thread thread = new Thread(source);
          thread.setDaemon(true);
          thread.start();
        }
        terminalMap.put(terminalId, sources);
      }
    }
    else {
      List<SocketSource> sources = terminalMap.remove(terminalId);
      if (null != sources && 0 != sources.size()) {
        for (SocketSource source : sources) {
          source.stop();
        }
      }
    }
  }

  private final class SocketSource implements Runnable {
    final private int port;
    final private String termId;
    final private Object lockObj = new Object();
    final private Thread worker;
    private boolean running = true;
    private Socket sock = null;
    private ServerSocket server = null;

    public SocketSource(JSONObject termConfigObject, String terminalId) {
      port = termConfigObject.getInt("port");
      termId = terminalId;
      worker = Thread.currentThread();
    }

    private boolean isRunning() {
      synchronized (lockObj) {
        return running;
      }
    }

    public void run() {
      try {
        server = new ServerSocket(port);
        server.setReuseAddress(true);
        StringBuilder sb = new StringBuilder();
        while (isRunning()) {
          sock = server.accept();
          BufferedReader r = new BufferedReader(new InputStreamReader(sock.getInputStream()));
          String line = r.readLine();
          while (null != line && isRunning()) {
            sb.setLength(0);
            sb.append(line);
            SocketSourceServer.this.publishToDestination(sb.toString().getBytes(), termId);
            line = r.readLine();
          }
          sock.close();
        }
      }
      catch (Exception e) {
        SocketSourceServer.this.log.error(e);
      }
      finally {
        try {
          if (null != sock) {
            sock.close();
          }
          if (null != server) {
            server.close();
          }
        }
        catch (IOException e2) {
          SocketSourceServer.this.log.error(e2);
        }
      }
    }

    public void stop() {
      synchronized (lockObj) {
        worker.interrupt();
        running = false;
        try {
          if (null != sock) {
            sock.close();
          }
          if (null != server) {
            server.close();
          }
        }
        catch (IOException e) {
          SocketSourceServer.this.log.warn(e);
        }
      }
    }
  }

}

