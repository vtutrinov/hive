// Compiled by build.sh on the host (JDK 8) and shipped as a .class file at
// /opt/hive/smoke-tests/SmokeTest.class so the runtime image stays JRE-only.
//
// Invoked by tests/smoke-test-ozone.sh test 8:
//   java -cp <hive+hadoop classpath> SmokeTest <metastore-uri> <db-name> <db-location>

import java.util.Collections;
import org.apache.hadoop.hive.conf.HiveConf;
import org.apache.hadoop.hive.metastore.HiveMetaStoreClient;
import org.apache.hadoop.hive.metastore.api.Database;

public class SmokeTest {
  public static void main(String[] args) throws Exception {
    if (args.length != 3) {
      System.err.println("usage: SmokeTest <metastore-uri> <db-name> <db-location>");
      System.exit(2);
    }
    String uri = args[0], dbName = args[1], loc = args[2];
    HiveConf conf = new HiveConf();
    conf.setVar(HiveConf.ConfVars.METASTORE_URIS, uri);
    HiveMetaStoreClient c = new HiveMetaStoreClient(conf);
    try {
      Database d = new Database(dbName, "hms-ozone smoke test", loc, Collections.emptyMap());
      c.createDatabase(d);
      System.out.println("CREATED " + dbName + " AT " + loc);
      Database got = c.getDatabase(dbName);
      System.out.println("READBACK " + got.getName() + " loc=" + got.getLocationUri());
      c.dropDatabase(dbName, true, true);
      System.out.println("DROPPED " + dbName);
    } finally {
      c.close();
    }
  }
}
