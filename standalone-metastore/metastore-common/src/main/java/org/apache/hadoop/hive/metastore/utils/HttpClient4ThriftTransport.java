/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.hadoop.hive.metastore.utils;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.HashMap;
import java.util.Map;
import org.apache.http.HttpEntity;
import org.apache.http.HttpHost;
import org.apache.http.HttpResponse;
import org.apache.http.HttpStatus;
import org.apache.http.client.HttpClient;
import org.apache.http.client.methods.HttpPost;
import org.apache.http.entity.ByteArrayEntity;
import org.apache.http.params.CoreConnectionPNames;
import org.apache.thrift.TConfiguration;
import org.apache.thrift.transport.TEndpointTransport;
import org.apache.thrift.transport.TTransportException;

/**
 * Apache HttpClient 4 counterpart of Thrift 0.16's THttpClient.
 *
 * <p>libthrift 0.23 switched THttpClient to Apache HttpClient 5. Hive's HTTP
 * authentication and SSL stack still uses HttpClient 4, so retain the compatible
 * transport here while sharing the 0.23 protocol runtime.</p>
 */
public class HttpClient4ThriftTransport extends TEndpointTransport {
  private URL url;
  private final ByteArrayOutputStream requestBuffer = new ByteArrayOutputStream();
  private InputStream inputStream;
  private int connectTimeout;
  private int readTimeout;
  private Map<String, String> customHeaders;
  private final HttpHost host;
  private final HttpClient client;

  public static class Factory extends org.apache.thrift.transport.TTransportFactory {
    private final String url;
    private final HttpClient client;

    public Factory(String url) {
      this(url, null);
    }

    public Factory(String url, HttpClient client) {
      this.url = url;
      this.client = client;
    }

    @Override
    public org.apache.thrift.transport.TTransport getTransport(
        org.apache.thrift.transport.TTransport trans) {
      try {
        return client == null ? new HttpClient4ThriftTransport(trans.getConfiguration(), url)
            : new HttpClient4ThriftTransport(trans.getConfiguration(), url, client);
      } catch (TTransportException e) {
        return null;
      }
    }
  }

  public HttpClient4ThriftTransport(TConfiguration config, String url) throws TTransportException {
    super(config);
    try {
      this.url = new URL(url);
      this.client = null;
      this.host = null;
    } catch (IOException e) {
      throw new TTransportException(e);
    }
  }

  public HttpClient4ThriftTransport(String url) throws TTransportException {
    this(new TConfiguration(), url);
  }

  public HttpClient4ThriftTransport(TConfiguration config, String url, HttpClient client)
      throws TTransportException {
    super(config);
    try {
      this.url = new URL(url);
      this.client = client;
      this.host = new HttpHost(this.url.getHost(),
          this.url.getPort() == -1 ? this.url.getDefaultPort() : this.url.getPort(),
          this.url.getProtocol());
    } catch (IOException e) {
      throw new TTransportException(e);
    }
  }

  public HttpClient4ThriftTransport(String url, HttpClient client) throws TTransportException {
    this(new TConfiguration(), url, client);
  }

  public void setConnectTimeout(int timeout) {
    connectTimeout = timeout;
    if (client != null) {
      client.getParams().setParameter(CoreConnectionPNames.CONNECTION_TIMEOUT, connectTimeout);
    }
  }

  public void setReadTimeout(int timeout) {
    readTimeout = timeout;
    if (client != null) {
      client.getParams().setParameter(CoreConnectionPNames.SO_TIMEOUT, readTimeout);
    }
  }

  public void setCustomHeaders(Map<String, String> headers) {
    customHeaders = headers;
  }

  public void setCustomHeader(String key, String value) {
    if (customHeaders == null) {
      customHeaders = new HashMap<>();
    }
    customHeaders.put(key, value);
  }

  @Override
  public void open() {
    // HTTP connections are opened per request.
  }

  @Override
  public void close() {
    if (inputStream != null) {
      try {
        inputStream.close();
      } catch (IOException ignored) {
        // Match THttpClient's best-effort close behavior.
      }
      inputStream = null;
    }
  }

  @Override
  public boolean isOpen() {
    return true;
  }

  @Override
  public int read(byte[] buf, int off, int len) throws TTransportException {
    if (inputStream == null) {
      throw new TTransportException("Response buffer is empty, no request.");
    }
    checkReadBytesAvailable(len);
    try {
      int ret = inputStream.read(buf, off, len);
      if (ret == -1) {
        throw new TTransportException("No more data available.");
      }
      countConsumedMessageBytes(ret);
      return ret;
    } catch (IOException e) {
      throw new TTransportException(e);
    }
  }

  @Override
  public void write(byte[] buf, int off, int len) {
    requestBuffer.write(buf, off, len);
  }

  private static void consume(HttpEntity entity) throws IOException {
    if (entity != null && entity.isStreaming()) {
      InputStream stream = entity.getContent();
      if (stream != null) {
        stream.close();
      }
    }
  }

  private void flushUsingHttpClient() throws TTransportException {
    if (client == null) {
      throw new TTransportException("Null HttpClient, aborting.");
    }
    byte[] data = requestBuffer.toByteArray();
    requestBuffer.reset();
    HttpPost post = null;
    InputStream stream = null;
    try {
      post = new HttpPost(url.getFile());
      post.setHeader("Content-Type", "application/x-thrift");
      post.setHeader("Accept", "application/x-thrift");
      post.setHeader("User-Agent", "Java/THttpClient/HC");
      if (customHeaders != null) {
        for (Map.Entry<String, String> header : customHeaders.entrySet()) {
          post.setHeader(header.getKey(), header.getValue());
        }
      }
      post.setEntity(new ByteArrayEntity(data));
      HttpResponse response = client.execute(host, post);
      int responseCode = response.getStatusLine().getStatusCode();
      stream = response.getEntity().getContent();
      if (responseCode != HttpStatus.SC_OK) {
        throw new TTransportException("HTTP Response code: " + responseCode);
      }
      byte[] buf = new byte[1024];
      ByteArrayOutputStream responseBuffer = new ByteArrayOutputStream();
      int len;
      do {
        len = stream.read(buf);
        if (len > 0) {
          responseBuffer.write(buf, 0, len);
        }
      } while (len != -1);
      try {
        consume(response.getEntity());
      } catch (IOException ignored) {
        // The server may not support keep-alive.
      }
      inputStream = new ByteArrayInputStream(responseBuffer.toByteArray());
    } catch (IOException e) {
      if (post != null) {
        post.abort();
      }
      throw new TTransportException(e);
    } finally {
      resetConsumedMessageSize(-1);
      if (stream != null) {
        try {
          stream.close();
        } catch (IOException e) {
          throw new TTransportException(e);
        }
      }
      if (post != null) {
        post.releaseConnection();
      }
    }
  }

  @Override
  public void flush() throws TTransportException {
    if (client != null) {
      flushUsingHttpClient();
      return;
    }
    byte[] data = requestBuffer.toByteArray();
    requestBuffer.reset();
    try {
      HttpURLConnection connection = (HttpURLConnection) url.openConnection();
      if (connectTimeout > 0) {
        connection.setConnectTimeout(connectTimeout);
      }
      if (readTimeout > 0) {
        connection.setReadTimeout(readTimeout);
      }
      connection.setRequestMethod("POST");
      connection.setRequestProperty("Content-Type", "application/x-thrift");
      connection.setRequestProperty("Accept", "application/x-thrift");
      connection.setRequestProperty("User-Agent", "Java/THttpClient");
      if (customHeaders != null) {
        for (Map.Entry<String, String> header : customHeaders.entrySet()) {
          connection.setRequestProperty(header.getKey(), header.getValue());
        }
      }
      connection.setDoOutput(true);
      connection.connect();
      connection.getOutputStream().write(data);
      int responseCode = connection.getResponseCode();
      if (responseCode != HttpURLConnection.HTTP_OK) {
        throw new TTransportException("HTTP Response code: " + responseCode);
      }
      inputStream = connection.getInputStream();
    } catch (IOException e) {
      throw new TTransportException(e);
    } finally {
      resetConsumedMessageSize(-1);
    }
  }
}
