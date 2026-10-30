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

package org.apache.hadoop.hive.serde2.thrift;

import static org.junit.Assert.assertEquals;

import java.util.Properties;
import java.util.UUID;
import org.apache.hadoop.conf.Configuration;
import org.apache.thrift.protocol.TStruct;
import org.apache.thrift.transport.TMemoryBuffer;
import org.junit.Test;

public class TestThriftUuidProtocols {
  private static final UUID UUID_VALUE = UUID.fromString("123e4567-e89b-42d3-a456-556642440000");

  @Test
  public void testBinarySortableUuidRoundTrip() throws Exception {
    TMemoryBuffer transport = new TMemoryBuffer(64);
    TBinarySortableProtocol protocol = new TBinarySortableProtocol(transport);
    protocol.initialize(new Configuration(), new Properties());
    protocol.writeStructBegin(new TStruct());
    protocol.writeUuid(UUID_VALUE);
    protocol.writeStructEnd();

    protocol.readStructBegin();
    assertEquals(UUID_VALUE, protocol.readUuid());
    protocol.readStructEnd();
  }

  @Test
  public void testCtlSeparatedUuidRoundTrip() throws Exception {
    TMemoryBuffer transport = new TMemoryBuffer(128);
    TCTLSeparatedProtocol protocol = new TCTLSeparatedProtocol(transport, 128);
    protocol.initialize(null, new Properties());
    protocol.writeStructBegin(new TStruct());
    protocol.writeUuid(UUID_VALUE);
    protocol.writeStructEnd();

    protocol.readStructBegin();
    assertEquals(UUID_VALUE, protocol.readUuid());
    protocol.readStructEnd();
  }
}
