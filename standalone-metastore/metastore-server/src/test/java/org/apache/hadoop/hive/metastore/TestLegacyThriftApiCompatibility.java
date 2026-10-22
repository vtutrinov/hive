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

package org.apache.hadoop.hive.metastore;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.hive.metastore.annotation.MetastoreCheckinTest;
import org.apache.hadoop.hive.metastore.api.NoSuchObjectException;
import org.apache.hadoop.hive.metastore.api.Table;
import org.apache.hadoop.hive.metastore.api.ThriftHiveMetastore;
import org.apache.hadoop.hive.metastore.client.builder.DatabaseBuilder;
import org.apache.hadoop.hive.metastore.client.builder.TableBuilder;
import org.apache.hadoop.hive.metastore.conf.MetastoreConf;
import org.apache.hadoop.hive.metastore.conf.MetastoreConf.ConfVars;
import org.apache.thrift.protocol.TBinaryProtocol;
import org.apache.thrift.transport.TSocket;
import org.apache.thrift.transport.TTransport;
import org.junit.After;
import org.junit.Assert;
import org.junit.Before;
import org.junit.Test;
import org.junit.experimental.categories.Category;

/**
 * Verifies that the Thrift APIs removed upstream by HIVE-26537 and restored for backward
 * compatibility (get_table, get_table_objects_by_name) are served by HMS. Older clients such as
 * Spark's built-in Hive 2.3 client call them over a plain Thrift connection.
 */
@Category(MetastoreCheckinTest.class)
public class TestLegacyThriftApiCompatibility {
  private static final String DB_NAME = "legacy_api_db";
  private static final String TABLE_NAME = "legacy_api_tbl";

  private Configuration conf;
  private HiveMetaStoreClient msc;
  private TTransport transport;
  private ThriftHiveMetastore.Client legacyClient;

  @Before
  public void setUp() throws Exception {
    conf = MetastoreConf.newMetastoreConf();
    // Behave like a production server: no test-only capability checks for old clients.
    MetastoreConf.setBoolVar(conf, ConfVars.HIVE_IN_TEST, false);
    MetaStoreTestUtils.setConfForStandloneMode(conf);
    int port = MetaStoreTestUtils.startMetaStoreWithRetry(conf);

    msc = new HiveMetaStoreClient(conf);
    msc.dropDatabase(DB_NAME, true, true, true);
    new DatabaseBuilder().setName(DB_NAME).create(msc, conf);
    new TableBuilder()
        .setDbName(DB_NAME)
        .setTableName(TABLE_NAME)
        .addCol("id", "int")
        .create(msc, conf);

    transport = new TSocket("localhost", port);
    transport.open();
    legacyClient = new ThriftHiveMetastore.Client(new TBinaryProtocol(transport));
  }

  @After
  public void tearDown() throws Exception {
    if (transport != null) {
      transport.close();
    }
    if (msc != null) {
      msc.dropDatabase(DB_NAME, true, true, true);
      msc.close();
    }
  }

  @Test
  public void testGetTable() throws Exception {
    Table table = legacyClient.get_table(DB_NAME, TABLE_NAME);
    Assert.assertEquals(DB_NAME, table.getDbName());
    Assert.assertEquals(TABLE_NAME, table.getTableName());
  }

  @Test(expected = NoSuchObjectException.class)
  public void testGetTableNotExists() throws Exception {
    legacyClient.get_table(DB_NAME, "no_such_table");
  }

  @Test
  public void testGetTableObjectsByName() throws Exception {
    List<Table> tables = legacyClient.get_table_objects_by_name(DB_NAME,
        Arrays.asList(TABLE_NAME, "no_such_table"));
    Assert.assertEquals(1, tables.size());
    Assert.assertEquals(TABLE_NAME, tables.get(0).getTableName());

    Assert.assertTrue(legacyClient.get_table_objects_by_name(DB_NAME, Collections.emptyList()).isEmpty());
  }
}
