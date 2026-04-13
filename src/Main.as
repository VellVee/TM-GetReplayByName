bool PermissionChecksPassed = false;
string inputNickname = "";
string savedMessage = "";
bool triggerDownloadNick = false;

// Batch Mode Globals
string g_batchModeText = "";
bool g_batchModeRunning = false;
string g_batchStatus = "";

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
                    UI::ShowNotification("GetReplayByName", "Starting nickname search for " + inputNickname + "...");
                    triggerDownloadNick = true;
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
    string safeMapName = Text::StripFormatCodes(map.MapName);
    string safeUserName = ghost.Nickname;
    string safeCurrTime = Regex::Replace(GetApp().OSLocalDate, "[/ ]", "_");
    string fmtGhostTime = Time::Format(ghost.Result.Time);
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

    while (true)
    {
        if (triggerDownloadNick)
        {
            if (!g_batchModeRunning) {
                g_batchModeText = inputNickname;
                inputNickname = "";
                g_batchModeRunning = true;
                startnew(BatchModeExecute);
            }
            triggerDownloadNick = false;
        }

        sleep(1000);
    }
}

void BatchModeExecute()
{
    CTrackMania@ app = cast<CTrackMania>(GetApp());
    if (app.RootMap is null) {
        g_batchStatus = "Error: Please play a map to batch-download to first.";
        UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(1.0, 0.0, 0.0, 1.0));
        g_batchModeRunning = false;
        return;
    }
    
    string mapUid = app.RootMap.MapInfo.MapUid;

    g_batchStatus = "Fetching map UUID from trackmania.io...";
    UI::ShowNotification("GetReplayByName", g_batchStatus);

    Net::HttpRequest@ req2 = Net::HttpRequest();
    req2.Method = Net::HttpMethod::Get;
    req2.Url = "https://trackmania.io/api/map/" + mapUid;
    req2.Headers["User-Agent"] = "GhostToReplayPlugin/1.0 by Antigravity";
    req2.Start();
    while(!req2.Finished()) yield();

    if (req2.ResponseCode() != 200) {
        g_batchStatus = "Error: Map translation failed (" + req2.ResponseCode() + ").";
        UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(1.0, 0.0, 0.0, 1.0));
        g_batchModeRunning = false;
        return;
    }
    
    Json::Value res2 = Json::Parse(req2.String());
    if (!res2.HasKey("mapId")) {
        g_batchStatus = "Error: Could not retrieve map UUID.";
        UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(1.0, 0.0, 0.0, 1.0));
        g_batchModeRunning = false;
        return;
    }
    string mapId = string(res2["mapId"]);

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

    for (uint i = 0; i < parsedNicknames.Length; i++) {
        string nick = parsedNicknames[i];
        
        if (parsedNicknames.Length > 1) {
            g_batchStatus = "Batch Processing (" + (i+1) + "/" + parsedNicknames.Length + "): " + nick;
            print("--- Processing " + (i+1) + " of " + parsedNicknames.Length + " ---");
        } else {
            g_batchStatus = "Processing: " + nick;
        }
        
        DownloadGhostForNicknameInternal(nick, mapId, app.RootMap);
        
        if (i < parsedNicknames.Length - 1) {
            sleep(1000);
        }
    }
    
    g_batchStatus = "All replays saved!";
    UI::ShowNotification("GetReplayByName", g_batchStatus, vec4(0.0, 1.0, 0.0, 1.0));
    g_batchModeText = "";
    g_batchModeRunning = false;
}

void DownloadGhostForNicknameInternal(const string &in nickname, const string &in mapId, CGameCtnChallenge@ map)
{
    print("Searching trackmania.io for '" + nickname + "'...");
    Net::HttpRequest@ req1 = Net::HttpRequest();
    req1.Method = Net::HttpMethod::Get;
    req1.Url = "https://trackmania.io/api/players/find?search=" + Net::UrlEncode(nickname);
    req1.Headers["User-Agent"] = "GhostToReplayPlugin/1.0 by Antigravity";
    req1.Start();
    while(!req1.Finished()) yield();

    if (req1.ResponseCode() != 200) {
        print("Error: TM.io search failed for " + nickname);
        return;
    }

    Json::Value res1 = Json::Parse(req1.String());
    if (res1.GetType() != Json::Type::Array || res1.Length == 0) {
        print("Error: Player not found on Trackmania.io: " + nickname);
        return;
    }
    string accountId = string(res1[0]["player"]["id"]);
    string actualName = string(res1[0]["player"]["name"]);
    print("Found player " + actualName + ", fetching map definitions...");
    
    print("Fetching map records for player...");
    string url3 = NadeoServices::BaseURLCore() + "/mapRecords/?accountIdList=" + accountId + "&mapIdList=" + mapId;
    auto req3 = NadeoServices::Get("NadeoServices", url3);
    req3.Start();
    while(!req3.Finished()) yield();
    
    if (req3.ResponseCode() != 200) {
        print("Error: Failed to fetch record from NadeoServices for " + actualName + " (" + req3.ResponseCode() + ")");
        return;
    }

    Json::Value res3 = Json::Parse(req3.String());
    if (res3.GetType() != Json::Type::Array || res3.Length == 0) {
        print("Error: " + actualName + " has no record on this map.");
        return;
    }

    string mapRecordId = string(res3[0]["mapRecordId"]);
    string ghostUrl = "https://prod.trackmania.core.nadeo.online/mapRecords/" + mapRecordId + "/replay";
    
    // Always append noise suffix to skirt Nadeo's aggressive ghost URL cache mechanisms 
    ghostUrl += "#" + Crypto::RandomBase64(12, url: true);
    
    print("Downloading ghost from core services...");
    auto dataFileMgr = TryGetDataFileMgr();
    if (dataFileMgr is null) {
        print("Error: Could not get DataFileMgr to download " + actualName);
        return;
    }

    auto ghostTask = dataFileMgr.Ghost_Download("", ghostUrl);
    uint timeout = 20000;
    uint currentTime = 0;
    while(ghostTask.Ghost is null && currentTime < timeout) {
        currentTime += 100;
        sleep(100);
    }
    
    CGameGhostScript@ ghost = cast<CGameGhostScript>(ghostTask.Ghost);
    if (ghost !is null) {
        string replayName = GetReplayFilename(ghost, map);
        string replayPath = "Downloaded/" + replayName;
        dataFileMgr.Replay_Save(replayPath, map, ghost);
        print("Saved replay to: " + replayPath + ".Replay.Gbx");
    } else {
        print("Error: Ghost download failed or timed out for " + actualName);
    }
}


