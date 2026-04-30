package keycloak.scenario.admin

import io.gatling.core.Predef._
import io.gatling.http.Predef._
import keycloak.scenario.{CommonSimulation, KeycloakScenarioBuilder}
import org.keycloak.benchmark.Config

// Repro for https://github.com/keycloak/keycloak/issues/46681
// With brute force protection + permanent lockout enabled, cold cache + parallel requests
// can cause users to be returned with enabled=false. This scenario detects that by
// asserting every user in every page has enabled=true.
class UserCrawlEnabledCheck extends CommonSimulation {

  private val ADMIN_ENDPOINT = "#{keycloakServer}/admin/realms/#{realm}"
  private val pageSize = Config.userPageSize
  private val numberOfPages = Config.userNumberOfPages

  private val builder = new KeycloakScenarioBuilder().serviceAccountToken()

  private val crawlChain = builder.chainBuilder
    .repeat(numberOfPages, "page") {
      exec(session =>
        session.set("max", pageSize)
               .set("first", session("page").as[Int] * pageSize)
      )
      .exec(
        http("#{realm}/users?first=#{first}&max=#{max}&briefRepresentation=false")
          .get(ADMIN_ENDPOINT + "/users")
          .header("Authorization", "Bearer #{token}")
          .queryParam("first", "#{first}")
          .queryParam("max", "#{max}")
          .queryParam("briefRepresentation", "false")
          .check(status.is(200))
          // Fails the request if any user in the page has enabled=false (the bug in #46681)
          .check(jsonPath("$[?(@.enabled == false)]").count.is(0))
      )
      .exitHereIfFailed
    }

  val userCrawlScenario = scenario("User Crawl Enabled Check").exec(crawlChain)

  setUp(
    userCrawlScenario.inject(constantConcurrentUsers(Config.concurrentUsers) during Config.measurementPeriod)
      .protocols(defaultHttpProtocol())
  ).assertions(
    global.failedRequests.percent.is(0),
    global.responseTime.mean.lte(Config.maxMeanResponseTime)
  )
}
