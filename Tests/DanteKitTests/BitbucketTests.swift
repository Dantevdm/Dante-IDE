import Foundation
import Testing
@testable import DanteKit

struct BitbucketTests {
    @Test func readsRemotes() {
        let https = BitbucketRemote.parse("https://sam@bitbucket.org/acme/shop-ui.git")
        #expect(https == BitbucketRemote(workspace: "acme", repository: "shop-ui", user: "sam", isSSH: false))
        #expect(https?.credentialURL == "https://sam@bitbucket.org/acme/shop-ui.git")
        #expect(BitbucketRemote.parse("git@bitbucket.org:acme/order-service.git")
            == BitbucketRemote(workspace: "acme", repository: "order-service", user: nil, isSSH: true))
        #expect(BitbucketRemote.parse("ssh://git@bitbucket.org/acme/shop")?.repository == "shop")
        #expect(BitbucketRemote.parse("https://bitbucket.org/acme/shop")?.credentialURL == "https://bitbucket.org/acme/shop.git")
        #expect(BitbucketRemote.parse("https://github.com/acme/shop.git") == nil)
        #expect(BitbucketRemote.parse("git@github.com:acme/shop.git") == nil)
        #expect(BitbucketRemote.parse("https://bitbucket.org/acme") == nil)
    }

    @Test func linksANewPullRequestPage() {
        let remote = BitbucketRemote.parse("https://bitbucket.org/acme/shop.git")!
        #expect(remote.newPullRequestURL(source: "feature/totals", destination: "main").absoluteString
            == "https://bitbucket.org/acme/shop/pull-requests/new?source=feature/totals&dest=main")
    }

    @Test func picksHowToSendTheSignIn() {
        let token = "ATAT" + "T-made-up"
        #expect(BitbucketSignIn.reading("protocol=https\nhost=bitbucket.org\nusername=sam\npassword=\(token)\n")?.header == "Bearer \(token)")
        let app = "ATB" + "B-made-up"
        #expect(BitbucketSignIn.reading("username=sam\npassword=\(app)\n")?.usesBasic == true)
        #expect(BitbucketSignIn.reading("username=x-token-auth\npassword=\(app)\n")?.usesBasic == false)
        #expect(BitbucketSignIn.reading("username=sam\n") == nil)
        #expect(BitbucketSignIn.reading("password=\(token)\n").map { "\($0)" } == "BitbucketSignIn(hidden)")
    }

    static let pullRequests = """
    {"values": [{"id": 12, "title": "Totals round half up", "state": "OPEN", "draft": false,
      "author": {"display_name": "Ana", "nickname": "ana"},
      "source": {"branch": {"name": "feature/totals"}}, "destination": {"branch": {"name": "main"}},
      "comment_count": 3, "task_count": 1, "updated_on": "2026-11-04T09:30:12.123456+00:00",
      "links": {"html": {"href": "https://bitbucket.org/acme/shop/pull-requests/12"}},
      "participants": [
        {"user": {"display_name": "Sam"}, "role": "REVIEWER", "approved": true, "state": "approved"},
        {"user": {"display_name": "Studio"}, "role": "REVIEWER", "approved": false, "state": "changes_requested"},
        {"user": {"display_name": "Lee"}, "role": "REVIEWER", "approved": false, "state": null},
        {"user": {"display_name": "Kim"}, "role": "PARTICIPANT", "approved": false, "state": null}]}],
     "next": "https://api.bitbucket.org/2.0/repositories/acme/shop/pullrequests?page=2"}
    """

    @Test func readsPullRequests() throws {
        let page = BitbucketJSON.pullRequests(Data(Self.pullRequests.utf8))
        let pr = try #require(page.values.first)
        #expect(pr.id == 12 && pr.source == "feature/totals" && pr.destination == "main")
        #expect(pr.author.name == "Ana")
        #expect(pr.url?.absoluteString == "https://bitbucket.org/acme/shop/pull-requests/12")
        #expect(pr.updated != nil)
        #expect(pr.approvals == 1 && pr.changesRequested == 1)
        #expect(pr.reviewers.map(\.person.name) == ["Sam", "Studio", "Lee"])
        #expect(page.next != nil)
    }

    @Test func readsCommentsAsThreads() {
        let json = """
        {"values": [
          {"id": 1, "user": {"display_name": "Sam"}, "content": {"raw": "Why round here?"}, "created_on": "2026-11-04T10:00:00+00:00",
           "inline": {"path": "src/orders/totals.ts", "to": 42, "from": null}},
          {"id": 2, "user": {"display_name": "Ana"}, "content": {"raw": "Tax rules."}, "created_on": "2026-11-04T10:05:00+00:00",
           "parent": {"id": 1}, "inline": {"path": "src/orders/totals.ts", "to": 42}},
          {"id": 3, "user": {"display_name": "Sam"}, "content": {"raw": "Looks good overall"}, "created_on": "2026-11-04T09:00:00+00:00"},
          {"id": 4, "user": {"display_name": "Lee"}, "content": {"raw": "gone"}, "deleted": true},
          {"id": 5, "user": {"display_name": "Lee"}, "content": {"raw": "Old line"}, "created_on": "2026-11-04T11:00:00+00:00",
           "inline": {"path": "src/orders/tax.ts", "from": 7, "to": null}, "resolution": {"type": "comment_resolution"}},
          {"id": 6, "user": {"display_name": "Kim"}, "content": {"raw": "+1"}, "created_on": "2026-11-04T10:10:00+00:00", "parent": {"id": 2}}]}
        """
        let comments = BitbucketJSON.comments(Data(json.utf8)).values
        #expect(comments.map(\.id) == [1, 2, 3, 5, 6])
        let threads = BitbucketThread.threads(comments)
        #expect(threads.map(\.id) == [3, 1, 5])
        #expect(threads[1].replies.map(\.id) == [2, 6])
        #expect(threads[1].root.path == "src/orders/totals.ts" && threads[1].root.line == 42)
        #expect(threads[2].root.onRemovedLine && threads[2].resolved)
        #expect(threads[0].root.path == nil)
    }

    @Test func explainsARefusal() {
        #expect(BitbucketError.refused(403).explanation.contains("read:pullrequest"))
        #expect(BitbucketError.noSignIn(ssh: true).explanation.contains("ssh"))
    }
}
