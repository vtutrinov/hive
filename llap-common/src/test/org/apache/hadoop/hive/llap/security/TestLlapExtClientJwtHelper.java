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

package org.apache.hadoop.hive.llap.security;

import static org.junit.Assert.assertEquals;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jws;
import io.jsonwebtoken.security.SignatureException;
import org.apache.hadoop.hive.conf.HiveConf;
import org.apache.hadoop.hive.conf.HiveConf.ConfVars;
import org.apache.hadoop.yarn.api.records.ApplicationId;
import org.junit.Test;

/**
 * Tests for {@link LlapExtClientJwtHelper} against the jjwt 0.12.x API
 * (CVE-2024-31033 migration): JWTs built with the new builder API must
 * round-trip through the new parser API and keep rejecting tampered input.
 */
public class TestLlapExtClientJwtHelper {

  private static final String SHARED_SECRET =
      "0123456789abcdef0123456789abcdef0123456789abcdef";

  private LlapExtClientJwtHelper createHelper() {
    HiveConf conf = new HiveConf();
    conf.set(ConfVars.LLAP_EXTERNAL_CLIENT_CLOUD_JWT_SHARED_SECRET_PROVIDER.varname,
        DefaultJwtSharedSecretProvider.class.getName());
    conf.set(ConfVars.LLAP_EXTERNAL_CLIENT_CLOUD_JWT_SHARED_SECRET.varname, SHARED_SECRET);
    return new LlapExtClientJwtHelper(conf);
  }

  @Test
  public void testJwtRoundTrip() {
    LlapExtClientJwtHelper helper = createHelper();
    ApplicationId appId = ApplicationId.newInstance(System.currentTimeMillis(), 42);
    String jwt = helper.buildJwtForLlap(appId);

    Jws<Claims> parsed = helper.parseClaims(jwt);
    assertEquals(LlapExtClientJwtHelper.LLAP_JWT_SUBJECT, parsed.getPayload().getSubject());
    assertEquals(appId.toString(),
        parsed.getPayload().get(LlapExtClientJwtHelper.LLAP_EXT_CLIENT_APP_ID));
  }

  @Test(expected = SignatureException.class)
  public void testTamperedJwtRejected() {
    LlapExtClientJwtHelper helper = createHelper();
    ApplicationId appId = ApplicationId.newInstance(System.currentTimeMillis(), 7);
    String jwt = helper.buildJwtForLlap(appId);
    String tampered = jwt.substring(0, jwt.lastIndexOf('.') + 1)
        + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    helper.parseClaims(tampered);
  }
}
