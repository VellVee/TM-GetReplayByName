bool PermissionChecksPassed = false;
string inputNickname = "";
string savedMessage = "";
string g_batchModeText = "";
bool g_batchModeRunning = false;
string g_batchStatus = "";

const string USER_AGENT = "GetReplayByName/1.0.0 by VellVee";

string ScrubFilename(const string &in name) {
    string scrubbed = name;
    string[] invalid = {
        "\\", "/", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t", "\v", "\f", "\0", "\x08", "$"
    };
    for (uint i = 0; i < invalid.Length; i++) {
        scrubbed = scrubbed.Replace(invalid[i], "_");
    }
    return scrubbed;
}

void RenderMenu()
{
    if (!PermissionChecksPassed) return;
    if (UI::BeginMenu("\\$999" + Icons::Download + "\\$z Get Replay By Name"))
    {
        if (UI::BeginMenu(Icons::ICursor + " Enter player nickname(s):"))
        {
            bool pressedEnter = false;
            inputNickname = UI::InputText("##InputNickname", inputNickname, pressedEnter, UI::InputTextFlags::EnterReturnsTrue);
            
            if (inputNickname != "") {
                if (pressedEnter || UI::MenuItem(Icons::Download + " Search and Create Replay")) {
                    if (!g_batchModeRunning) {
                        g_batchModeText = inputNickname;
                        inputNickname = "";
                        g_batchModeRunning = true;
                        startnew(BatchModeExecute);
                    }
                }
            }

            UI::EndMenu();
        }

        UI::Separator();
        CTrackMania@ app = cast<CTrackMania>(GetApp());
        if (app.RootMap !is null) {
            if (UI::MenuItem(Icons::Clipboard + " Copy Map Name & Author")) {
                string safeMapName = Text::StripFormatCodes(app.RootMap.MapName);
                string safeAuthorName = Text::StripFormatCodes(app.RootMap.AuthorNickName);
                IO::SetClipboard(safeMapName + " by " + safeAuthorName);
                UI::ShowNotification("GetReplayByName", "Copied to clipboard:\n" + safeMapName + " by " + safeAuthorName, vec4(0.0, 1.0, 0.0, 1.0));
            }
        } else {
            UI::TextDisabled("Load a map to copy info");
        }

        UI::EndMenu();
    }
}

CGameDataFileManagerScript@ TryGetDataFileMgr()
{
    CTrackMania@ app = cast<CTrackMania>(GetApp());
    if (app !is null)
    {
        CSmArenaRulesMode@ playgroundScript = cast<CSmArenaRulesMode>(app.PlaygroundScript);
        if (playgroundScript !is null)
        {
            CGameDataFileManagerScript@ dataFileMgr = cast<CGameDataFileManagerScript>(playgroundScript.DataFileMgr);
            if (dataFileMgr !is null)
            {
                return dataFileMgr;
            }
        }
    }
    return null;
}

bool HasPermission()
{
    bool hasPermission = true;
    if (!Permissions::CreateLocalReplay())
    {
        error("Missing permission client_CreateLocalReplay");
        hasPermission = false;
    }
    if (!Permissions::OpenReplayEditor())
    {
        error("Missing permission client_OpenReplayEditor");
        hasPermission = false;
    }
    return hasPermission;
}

string GetReplayFilename(CGameGhostScript@ ghost, CGameCtnChallenge@ map)
{
    if (ghost is null || map is null)
    {
        error("Error getting replay filename, ghost or map input is null");
        return "";
    }
    string safeMapName = ScrubFilename(Text::StripFormatCodes(map.MapName));
    string safeUserName = ScrubFilename(Text::StripFormatCodes(ghost.Nickname));
    string safeCurrTime = Time::FormatString("%Y-%m-%d_%H-%M-%S", Time::Stamp);
    string fmtGhostTime = ScrubFilename(Time::Format(ghost.Result.Time));
    return safeMapName + "_" + safeUserName + "_" + safeCurrTime + "_(" + fmtGhostTime + ")";
}

void Main()
{
    if (!HasPermission())
    {
        error("Insufficient permissions to use " + Meta::ExecutingPlugin().Name + ". Exiting...");
        return;
    }
    else
    {
        PermissionChecksPassed = true;
    }

    NadeoServices::AddAudience("NadeoServices");
    while (!NadeoServices::IsAuthenticated("NadeoServices")) {
        yield();
    }
}

void BatchModeExecute()
{
    CTrackMania@ app = cast<CTrackMania>(GetApp());
    if (app.RootMap is null || app.CurrentPlayground is null) {
        g_batchStatus = "Error: Please play a map to batch-download to first.";
        UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(1.0, 0.0, 0.0, 1.0));
        g_batchModeRunning = false;
        return;
    }
    
    string mapUid = app.RootMap.MapInfo.MapUid;

    g_batchStatus = "Fetching map UUID from trackmania.io...";
    UI::ShowNotification("GetReplayByName", g_batchStatus);

    Net::HttpRequest@ mapInfoReq = Net::HttpRequest();
    mapInfoReq.Method = Net::HttpMethod::Get;
    mapInfoReq.Url = "https://trackmania.io/api/map/" + mapUid;
    mapInfoReq.Headers["User-Agent"] = USER_AGENT;
    mapInfoReq.Start();
    while(!mapInfoReq.Finished()) yield();

    if (mapInfoReq.ResponseCode() != 200) {
        g_batchStatus = "Error: Map translation failed (" + mapInfoReq.ResponseCode() + ").";
        UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(1.0, 0.0, 0.0, 1.0));
        g_batchModeRunning = false;
        return;
    }
    
    Json::Value mapInfoRes = Json::Parse(mapInfoReq.String());
    if (mapInfoRes.GetType() == Json::Type::Null || !mapInfoRes.HasKey("mapId")) {
        g_batchStatus = "Error: Could not retrieve map UUID.";
        UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(1.0, 0.0, 0.0, 1.0));
        g_batchModeRunning = false;
        return;
    }
    string mapId = string(mapInfoRes["mapId"]);

    string[] parsedNicknames;
    string[] lines = g_batchModeText.Split("\n");
    for (uint i = 0; i < lines.Length; ++i) {
        string sanitized = lines[i].Replace(",", ";").Replace(" ", ";");
        string[] elements = sanitized.Split(";");
        for (uint j = 0; j < elements.Length; ++j) {
            string nick = elements[j].Trim();
            if (nick != "") {
                parsedNicknames.InsertLast(nick);
            }
        }
    }

    if (parsedNicknames.Length == 0) {
        g_batchStatus = "Error: No valid nicknames parsed.";
        UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(1.0, 0.0, 0.0, 1.0));
        g_batchModeRunning = false;
        return;
    }

    if (parsedNicknames.Length > 1) {
        g_batchStatus = "Starting batch download for " + parsedNicknames.Length + " players.";
    } else {
        g_batchStatus = "Searching for player...";
    }
    UI::ShowNotification("GetReplayByName", g_batchStatus);

    uint successCount = 0;
    for (uint i = 0; i < parsedNicknames.Length; i++) {
        if (app.RootMap is null) {
            UI::ShowNotification("GetReplayByName", "Map exited! Download aborted.", vec4(1.0, 0.0, 0.0, 1.0));
            break;
        }

        string nick = parsedNicknames[i];
        
        if (parsedNicknames.Length > 1) {
            g_batchStatus = "Batch Processing (" + (i+1) + "/" + parsedNicknames.Length + "): " + nick;
            print("--- Processing " + (i+1) + " of " + parsedNicknames.Length + " ---");
        } else {
            g_batchStatus = "Processing: " + nick;
        }
        
        if (DownloadGhostForNicknameInternal(nick, mapId, app.RootMap)) {
            successCount++;
        }
        
        if (i < parsedNicknames.Length - 1) {
            sleep(1000);
        }
    }
    
    if (successCount > 0) {
        g_batchStatus = "Saved " + successCount + "/" + parsedNicknames.Length + " replays!";
        UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(0.0, 1.0, 0.0, 1.0));
    } else {
        g_batchStatus = "Error: No replays could be saved.";
        UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(1.0, 0.0, 0.0, 1.0));
    }
    g_batchModeText = "";
    g_batchModeRunning = false;
}

bool DownloadGhostForNicknameInternal(const string &in nickname, const string &in mapId, CGameCtnChallenge@ map)
{
    print("Searching trackmania.io for '" + nickname + "'...");
    Net::HttpRequest@ searchReq = Net::HttpRequest();
    searchReq.Method = Net::HttpMethod::Get;
    searchReq.Url = "https://trackmania.io/api/players/find?search=" + Net::UrlEncode(nickname);
    searchReq.Headers["User-Agent"] = USER_AGENT;
    searchReq.Start();
    while(!searchReq.Finished()) yield();

    if (searchReq.ResponseCode() != 200) {
        warn("TM.io search failed for " + nickname + " (" + searchReq.ResponseCode() + ")");
        return false;
    }

    if (searchReq.String().Length == 0) {
        warn("Received empty response from Trackmania.io for " + nickname);
        return false;
    }

    Json::Value searchRes = Json::Parse(searchReq.String());
    if (searchRes.GetType() != Json::Type::Array || searchRes.Length == 0) {
        warn("Player not found on Trackmania.io: " + nickname);
        return false;
    }

    Json::Value firstResult = searchRes[0];
    if (firstResult.GetType() != Json::Type::Object || !firstResult.HasKey("player")) {
        warn("Unexpected API response shape for: " + nickname);
        return false;
    }
    Json::Value playerObj = firstResult["player"];
    if (playerObj.GetType() != Json::Type::Object || !playerObj.HasKey("id") || !playerObj.HasKey("name")) {
        warn("Player object missing required fields for: " + nickname);
        return false;
    }

    string accountId = string(playerObj["id"]);
    string actualName = string(playerObj["name"]);
    print("Found player " + actualName + ", fetching map records...");
    
    string recordUrl = NadeoServices::BaseURLCore() + "/mapRecords/?accountIdList=" + accountId + "&mapIdList=" + mapId;
    auto recordReq = NadeoServices::Get("NadeoServices", recordUrl);
    recordReq.Start();
    while(!recordReq.Finished()) yield();
    
    if (recordReq.ResponseCode() != 200) {
        warn("Failed to fetch record from NadeoServices for " + actualName + " (" + recordReq.ResponseCode() + ")");
        return false;
    }

    Json::Value recordRes = Json::Parse(recordReq.String());
    if (recordRes.GetType() != Json::Type::Array || recordRes.Length == 0) {
        warn(actualName + " has no record on this map.");
        return false;
    }

    Json::Value firstRecord = recordRes[0];
    if (firstRecord.GetType() != Json::Type::Object || !firstRecord.HasKey("mapRecordId")) {
        warn("Record response missing mapRecordId for " + actualName);
        return false;
    }

    string mapRecordId = string(firstRecord["mapRecordId"]);
    string ghostUrl = "https://prod.trackmania.core.nadeo.online/mapRecords/" + mapRecordId + "/replay";
    
    // Append cache-bust query parameter to bypass Nadeo's aggressive ghost URL caching
    ghostUrl += "?cb=" + Crypto::RandomBase64(12);
    
    print("Downloading ghost from core services...");
    auto dataFileMgr = TryGetDataFileMgr();
    if (dataFileMgr is null) {
        warn("Could not get DataFileMgr to download " + actualName);
        return false;
    }

    auto ghostTask = dataFileMgr.Ghost_Download("", ghostUrl);
    uint timeout = 20000;
    uint elapsed = 0;
    while(ghostTask.Ghost is null && !ghostTask.HasFailed && elapsed < timeout) {
        elapsed += 100;
        if (elapsed % 5000 == 0) {
            print("Still downloading ghost for " + actualName + "... (" + (elapsed / 1000) + "s)");
        }
        sleep(100);
    }
    
    CGameGhostScript@ ghost = cast<CGameGhostScript>(ghostTask.Ghost);
    if (ghost is null) {
        warn("Ghost download failed or timed out for " + actualName);
        return false;
    }

    if (map is null) {
        warn("Map was unloaded during download for " + actualName);
        return false;
    }

    string replayName = GetReplayFilename(ghost, map);
    string replayPath = "Downloaded/" + replayName;
    dataFileMgr.Replay_Save(replayPath, map, ghost);
    print("Saved replay to: " + replayPath + ".Replay.Gbx");
    return true;
}