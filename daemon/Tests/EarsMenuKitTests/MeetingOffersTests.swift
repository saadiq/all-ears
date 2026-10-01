import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("MeetingOffers")
struct MeetingOffersTests {
  private func menu(_ phase: ConnectionPhase = .connected, sessions: [Session] = []) -> MenuState {
    var state = MenuState()
    if phase != .connecting {
      MenuStateReducer.connected(
        &state, daemon: "earsd", snapshot: makeSnapshot(sessions: sessions))
    }
    if phase == .unreachable { MenuStateReducer.disconnected(&state) }
    return state
  }

  private func activity(_ list: [MeetingActivityStatus]) -> MeetingActivityState {
    var state = MeetingActivityState()
    state.activity = list
    return state
  }

  private let teams = MeetingActivityStatus(
    source: SourceID("app:com.microsoft.teams2"), bundleID: "com.microsoft.teams2",
    label: "Teams", active: true, episode: "com.microsoft.teams2#1")

  @Test("connected and idle: one offer per active meeting, in activity order")
  func offersWhenIdle() {
    let idle = menu()
    let offers = MeetingOffers.render(activity([zoomActivity(), teams]), menu: idle)
    #expect(
      offers == [
        MeetingOffer(source: "app:us.zoom.xos", episode: "us.zoom.xos#1", label: "Zoom"),
        MeetingOffer(
          source: "app:com.microsoft.teams2", episode: "com.microsoft.teams2#1", label: "Teams"),
      ])
    // The stack's renderer is untouched: plain Start Recording still shows.
    #expect(MenuRenderer.render(idle, now: instant(0)).verbs == [.startRecording])
  }

  @Test("no offer while a session is active or paused")
  func noOfferWhileLive() {
    let live = activity([zoomActivity()])
    #expect(MeetingOffers.render(live, menu: menu(sessions: [makeSession()])).isEmpty)
    #expect(
      MeetingOffers.render(live, menu: menu(sessions: [makeSession(state: .paused)])).isEmpty)
  }

  @Test("no offer unless connected")
  func noOfferUnlessConnected() {
    let live = activity([zoomActivity()])
    #expect(MeetingOffers.render(live, menu: menu(.connecting)).isEmpty)
    #expect(MeetingOffers.render(live, menu: menu(.unreachable)).isEmpty)
  }

  @Test("an ended meeting is not offered")
  func inactiveNotOffered() {
    #expect(MeetingOffers.render(activity([zoomActivity(active: false)]), menu: menu()).isEmpty)
  }

  @Test("an unlabelled source is offered under its source id")
  func labelFallsBackToSourceID() {
    let offers = MeetingOffers.render(activity([zoomActivity(label: "")]), menu: menu())
    #expect(offers.map(\.label) == ["app:us.zoom.xos"])
  }

  @Test("the row reads Start Recording ‘<label>’ Meeting")
  func menuTitle() {
    let offer = MeetingOffer(source: "app:us.zoom.xos", episode: "us.zoom.xos#1", label: "Zoom")
    #expect(offer.menuTitle == "Start Recording ‘Zoom’ Meeting")
    #expect(offer.id == "app:us.zoom.xos")
  }
}
