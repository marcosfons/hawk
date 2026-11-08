import HawkKit
import Testing

@Suite struct AndroidManagementTests {
    @Test func ownersUsersAndProfiles() {
        let m = Management.parse([
            "owners": "User 0: admin=com.example.mdm/.Admin,DeviceOwner\nUser 150: admin=com.example.agent/.Receiver,ProfileOwner\n",
            "users": "Users:\n\tUserInfo{0:Owner:4c13} running\n\tUserInfo{150:Secure Folder:61010} running\n\tUserInfo{10:Work:30} \n",
        ])
        #expect(m.isManaged && m.deviceOwner == "com.example.mdm" && m.profileOwners == [150: "com.example.agent"])
        #expect(m.users.map(\.id) == [0, 150, 10])
        #expect(m.users[1].name == "Secure Folder" && m.users[1].managedProfile && m.users[1].running)
        #expect(m.users[2].managedProfile && !m.users[2].running)
        #expect(!m.users[0].managedProfile)
    }

    @Test func unmanagedAndGarbage() {
        let m = Management.parse(["owners": "no owners\n", "users": "garbage{\nUserInfo{x:y}\n"])
        #expect(!m.isManaged && m.users.isEmpty)
    }
}
