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
package org.apache.hadoop.hive.metastore.tools.schematool;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;
import java.util.Optional;

import org.apache.hadoop.hive.metastore.HiveMetaException;
import org.apache.hadoop.hive.metastore.conf.MetastoreConf;

import static org.apache.hadoop.hive.metastore.IMetaStoreSchemaInfo.SQL_FILE_EXTENSION;

/**
 * Initialize the metastore schema.
 */
class SchemaToolTaskInit extends SchemaToolTask {
  private boolean validate = true;
  private String toVersion;

  @Override
  void setCommandLineArguments(SchemaToolCommandLine cl) {
    if (cl.hasOption("initSchemaTo")) {
      this.toVersion = cl.getOptionValue("initSchemaTo");
      this.validate = false;
    }
  }

  private void ensureToVersion() throws HiveMetaException {
    if (toVersion != null) {
      return;
    }

    // If null then current hive version is used
    toVersion = schemaTool.getMetaStoreSchemaInfo().getHiveSchemaVersion();
    System.out.println("Initializing the schema to: " + toVersion);
  }

  @Override
  void execute() throws HiveMetaException {
    ensureToVersion();

    schemaTool.testConnectionToMetastore();
    System.out.println("Starting metastore schema initialization to " + toVersion);

    String initScriptDir = schemaTool.getMetaStoreSchemaInfo().getMetaStoreScriptDir();
    String protoScriptFile = schemaTool.getMetaStoreSchemaInfo().generateInitFileName(toVersion);

    try {
      File initScriptFile = subUser(initScriptDir, protoScriptFile);
      System.out.println("Initialization script " + initScriptFile.getAbsolutePath());
      if (!schemaTool.isDryRun()) {
        schemaTool.execSql(initScriptFile.getParent(), initScriptFile.getName());
        System.out.println("Initialization script completed");
      }
    } catch (IOException e) {
      throw new HiveMetaException("Schema initialization FAILED! Metastore state would be inconsistent!", e);
    }

    if (validate) {
      schemaTool.verifySchemaVersion();
    }
  }

  private File subUser(String parent, String filename) throws IOException {
    String dbType = schemaTool.getDbType();
    String user = Optional.ofNullable(schemaTool.getHiveUser()).orElse(schemaTool.userName);
    String customSchemaOwner = MetastoreConf.getVar(schemaTool.conf, MetastoreConf.ConfVars.SCHEMA_OWNER);
    String schemaOwner = customSchemaOwner.isEmpty() ? user : customSchemaOwner;
    String customSchemaName = MetastoreConf.getVar(schemaTool.conf, MetastoreConf.ConfVars.SCHEMA_NAME);
    String schemaName = customSchemaName.isEmpty() ? user : customSchemaName;
    String prefix = filename.replaceAll("(.*)\\." + dbType + "\\." + SQL_FILE_EXTENSION, "$1");
    File createFile = File.createTempFile(prefix + "-" + dbType, ".sql");
    File proto = new File(parent, filename);

    System.out.println("user: " + user);
    System.out.println("schemaOwner: " + schemaOwner);
    System.out.println("schemaName: " + schemaName);

    try (BufferedWriter writer = new BufferedWriter(new FileWriter(createFile));
         BufferedReader reader = new BufferedReader(new FileReader(proto))
    ) {
      reader.lines()
              .map(s -> s.replace("_REPLACE_WITH_USER_", user)
                      .replace("_REPLACE_WITH_OWNER_", schemaOwner)
                      .replace("_REPLACE_WITH_SCHEMA_", schemaName)
              )
              .forEach(s -> {
                try {
                  writer.write(s);
                  writer.newLine();
                } catch (IOException e) {
                  throw new RuntimeException("Unable to write script to file ", e);
                }
              });
    }
    return createFile;
  }
}
