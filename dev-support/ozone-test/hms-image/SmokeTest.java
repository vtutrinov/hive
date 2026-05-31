// Compiled by build.sh on the host (JDK 8) and shipped as a .class file at
// /opt/hive/smoke-tests/SmokeTest.class so the runtime image stays JRE-only.
//
// Invoked by tests/smoke-test-ozone.sh test 8:
//   java -cp <hive+hadoop classpath> SmokeTest <metastore-uri> <db-name> <db-location>

import java.util.Arrays;
import java.util.Collections;
import org.apache.hadoop.hive.conf.HiveConf;
import org.apache.hadoop.hive.metastore.HiveMetaStoreClient;
import org.apache.hadoop.hive.metastore.api.Database;
import org.apache.hadoop.hive.metastore.api.FieldSchema;
import org.apache.hadoop.hive.metastore.api.SerDeInfo;
import org.apache.hadoop.hive.metastore.api.StorageDescriptor;
import org.apache.hadoop.hive.metastore.api.Table;

public class SmokeTest {
  public static void main(String[] args) throws Exception {
    if (args.length != 3) {
      System.err.println("usage: SmokeTest <metastore-uri> <db-name> <db-location>");
      System.exit(2);
    }
    String uri = args[0], dbName = args[1], dbLoc = args[2];
    HiveConf conf = new HiveConf();
    conf.setVar(HiveConf.ConfVars.METASTORE_URIS, uri);
    HiveMetaStoreClient c = new HiveMetaStoreClient(conf);
    try {
      // 1. CREATE DATABASE (metadata-only)
      Database d = new Database(dbName, "hms-ozone smoke test", dbLoc, Collections.emptyMap());
      c.createDatabase(d);
      System.out.println("CREATED " + dbName + " AT " + dbLoc);

      // 2. Read back
      Database got = c.getDatabase(dbName);
      System.out.println("READBACK " + got.getName() + " loc=" + got.getLocationUri());

      // 3. CREATE TABLE -- forces HMS.Warehouse.mkdirs() against the table location,
      //    which exercises the actual FileSystem (ofs://) write path on Hadoop 3.4.x
      //    + Ozone client. If the FS classpath is broken (e.g. protobuf missing),
      //    this will throw at runtime even though metadata-only ops would succeed.
      String tableName = "smoke_tbl";
      String tableLoc = dbLoc + "/" + tableName;
      Table t = new Table();
      t.setDbName(dbName);
      t.setTableName(tableName);
      t.setTableType("MANAGED_TABLE");
      t.setOwner("hms-smoke");
      StorageDescriptor sd = new StorageDescriptor();
      sd.setCols(Arrays.asList(new FieldSchema("id", "int", "id col")));
      sd.setLocation(tableLoc);
      sd.setInputFormat("org.apache.hadoop.mapred.TextInputFormat");
      sd.setOutputFormat("org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat");
      SerDeInfo serde = new SerDeInfo();
      serde.setName(tableName);
      serde.setSerializationLib("org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe");
      sd.setSerdeInfo(serde);
      t.setSd(sd);
      c.createTable(t);
      System.out.println("CREATED TABLE " + dbName + "." + tableName + " AT " + tableLoc);

      Table gotT = c.getTable(dbName, tableName);
      System.out.println("READBACK TABLE " + gotT.getDbName() + "." + gotT.getTableName()
          + " loc=" + gotT.getSd().getLocation());

      // 4. Cleanup
      c.dropTable(dbName, tableName, true /*deleteData*/, false);
      System.out.println("DROPPED TABLE " + tableName);
      c.dropDatabase(dbName, true, true);
      System.out.println("DROPPED DB " + dbName);
    } finally {
      c.close();
    }
  }
}
