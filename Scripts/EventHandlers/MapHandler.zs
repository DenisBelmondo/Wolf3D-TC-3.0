/*
 * Copyright (c) 2024 AFADoomer
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

class MapHandler : StaticEventHandler
{
	WolfMapParser parsedmaps;
	Array<DataFile> datafiles;
	Array<ActorMap> actormapping;
	ParsedMap curmap, queuedmap;
	Array<int> activatedfloors;

	override void OnRegister()
	{
		ParseGameMaps();
		ParseActorMaps(actormapping);
	}

	void ParseGameMaps()
	{
		console.printf("Parsing map data...");

		// Parse the demo map first
		let d = DataFile.Find(datafiles, "Custom Maps", "Data/EditorThings.map");
		WolfMapParser.Parse(parsedmaps, d);

		for (int l = 0; l < Wads.GetNumLumps(); l++)
		{
			String lumpname = Wads.GetLumpFullName(l);
			String shortlumpname = Wads.GetLumpName(l);
			if (shortlumpname ~== "gamemaps")
			{
				String headname = lumpname;
				headname.Substitute("gamemaps", "maphead");

				if (Wads.CheckNumForFullName(headname) > -1)
				{
					let e = DataFile.Find(datafiles, lumpname, lumpname, headname);
					WolfMapParser.Parse(parsedmaps, e);
				}
			}
			else if (lumpname.Mid(lumpname.Length() - 4) ~== ".map" || lumpname.Mid(lumpname.Length() - 4) ~== ".lvl")
			{
				d.path = lumpname;
				WolfMapParser.Parse(parsedmaps, d);
			}
		}
	}

	override void NetworkProcess(ConsoleEvent e)
	{
		if (!parsedmaps) { return; }

		if (e.Name.Left(10) == "initialize")
		{
			String mapname = "Wolf3D TC Test";
			String datafile = "";
			if (e.Name.Length() > 11)
			{
				String data = e.Name.Mid(11);

				Array<String> splitdata;
				data.Split(splitdata, ":");

				mapname = splitdata[0];
				if (e.IsManual) { mapname.Substitute("_", " "); }

				if (splitdata.Size() > 1) { datafile = splitdata[1]; }
			}

			queuedmap = parsedmaps.GetMapData(mapname, datafile);

			level.ChangeLevel("Level");
		}
		else if (e.Name == "listmaps")
		{
			for (int m = 0; m < parsedmaps.maps.Size(); m++)
			{
				console.printf("%s (%s)", parsedmaps.maps[m].mapname, parsedmaps.maps[m].datafile.path);
			}
		}
	}

	override void WorldLoaded(WorldEvent e)
	{
		if (e.IsSaveGame) { return; }

		if (level.mapname ~== "Level" && queuedmap)
		{
			curmap = queuedmap;
			curmap.Initialize();
			activatedfloors.Clear();

			if (curmap.info)
			{
				console.PrintfEx(PRINT_HIGH | PRINT_NONOTIFY, "\c[%s]%s\n", g_sod <= 0 ? "DarkRed" : "Gold", StringTable.Localize(curmap.info.levelname, false));
				if (curmap.info.nextmap.length()) { level.nextmap = curmap.info.nextmap; }
				if (curmap.info.nextsecretmap.length()) { level.nextsecretmap = curmap.info.nextsecretmap; }
				S_ChangeMusic(curmap.info.music);
			}
			else
			{
				console.PrintfEx(PRINT_HIGH | PRINT_NONOTIFY, "\c[%s]%s\n", g_sod <= 0 ? "DarkRed" : "Gold", curmap.mapname);
				level.nextmap = level.nextsecretmap = level.mapname;
			}
		}
		else
		{
			queuedmap = null;
			curmap = null;
		}
	}

	override void WorldTick()
	{
		// TODO: Fix automap view traversal in a better way
		// Check for noclipping players; allow them to see through void space
		// by clearing line textures that normally block automap sight traversal
		//
		// We are assuming that if they are noclipping, they don't care about
		// seeing parts of the map that they shouldn't actually be able to see
		if (!(level.mapname ~== "Level") || !curmap || level.time % 10) { return; } // only check every 10 tics for performance

		int noclip;
		for (int p = 0; p < MAXPLAYERS; p++)
		{
			if (playeringame[p]) { noclip += players[p].cheats & CF_NOCLIP; }
		}

		if (!!noclip != curmap.noclip)
		{
			TextureID tex = TexMan.CheckForTexture(noclip ? "-" : "BLACK", TexMan.Type_Any);
			for (int s = 0; s < curmap.voidspace.Size(); s++)
			{
				let sec = curmap.voidspace[s];
				for (int l = 0; l < sec.lines.Size(); l++)
				{
					let ln = sec.lines[l];
					for (int s = 0; s < 2; s++)
					{
						if (ln.sidedef[s])
						{
							ln.sidedef[s].SetTexture(side.top, tex);
							ln.sidedef[s].SetTexture(side.bottom, tex);
						}
					}
				}
			}
			curmap.noclip = !!noclip;
		}
	}

	override void WorldLinePreActivated(WorldEvent e)
	{
		if (level.mapname ~== "Level")
		{
			Line ln = e.ActivatedLine;
			if (ln.special != 80 || ln.args[0] != 10) { return; }

			int side = 0;
			for (int s = 0; s < 2; s++)
			{
				let sidedef = ln.sidedef[s];
				if (sidedef.sector.CenterFloor() == e.Thing.cursector.CenterFloor()) { side = s; }
			}

			String nextmap = ln.args[2] == 10 ? level.nextsecretmap : level.nextmap;

			if (nextmap ~== "Level")
			{
				// If this is a custom map with no corresponding MAPINFO, just loop this map
				queuedmap = curmap;
			}
			else if (nextmap.left(6) == "enDSeQ" || nextmap == "")
			{
				// End of episode/game
			}
			else
			{
				LevelInfo nextinfo = LevelInfo.FindLevelInfo(nextmap);
				if (nextinfo)
				{
					queuedmap = parsedmaps.GetMapDataByNumber(nextinfo.levelnum);
					level.nextmap = level.nextsecretmap = "Level";
				}
			}
		}
	}

	override void PlayerSpawned (PlayerEvent e)
	{
		PlacePlayer(e.PlayerNumber);
	}

	override void PlayerRespawned (PlayerEvent e)
	{
		PlacePlayer(e.PlayerNumber);
	}

	void PlacePlayer(int p)
	{
		if (!(level.mapname ~== "Level")) { return; }
		if (!curmap) { return; }
		if (!playeringame[p] || !players[p].mo) { return; }

		Vector2 pos = curmap.startspot;

		int a = ActorAt(pos);
		double angle = 90 - (a - 0x13) * 90;

		players[p].mo.SetOrigin((curmap.GetNextSpot(pos, angle, p - 1, deathmatch), 0), false);
		players[p].mo.angle = angle;
	}

	void ParseActorMaps(out Array<ActorMap> actormaps)
	{
		int lump = -1;
		lump = Wads.CheckNumForFullName("Data/ActorCodes.txt");

		if (lump != -1)
		{
			Array<String> lines;
			String data = Wads.ReadLump(lump);
			data.Split(lines, "\n");

			for (int i = 0; i < lines.Size(); i++)
			{
				// Skip blank lines and comments
				if (lines[i].Left(2) == "//" || !lines[i].length()) { continue; }

				Array<String> values;
				lines[i].split(values, "=");

				if (values.Size() < 2) { continue; }

				ActorMap m = ActorMap.Add(values[0].ToInt(), values[1]);
				if (m) { actormapping.Push(m); }
			}
		}
	}

	static clearscope MapHandler Get()
	{
		return MapHandler(StaticEventHandler.Find("MapHandler"));
	}

	static ui ParsedMap GetCurrentMap()
	{
		MapHandler this = MapHandler.Get();
		if (!this) { return null; }

		return this.curmap;
	}

	static int GetGameType()
	{
		MapHandler this = MapHandler.Get();
		if (!this || !this.curmap) { return -1; }

		return this.curmap.gametype;
	}

	static ui String GetMusic()
	{
		MapHandler this = MapHandler.Get();
		if (!this || !this.curmap || !this.curmap.info) { return level.music; }

		return this.curmap.info.music;
	}

	static int TileAt(Vector2 pos)
	{
		MapHandler this = MapHandler.Get();
		if (!this || !this.curmap) { return -1; }

		pos = ParsedMap.CoordsToGrid(pos);

		return this.curmap.TileAt(pos);
	}

	static int ActorAt(Vector2 pos)
	{
		MapHandler this = MapHandler.Get();
		if (!this || !this.curmap) { return -1; }

		pos = ParsedMap.CoordsToGrid(pos);

		return this.curmap.ActorAt(pos);
	}

	static bool ClearTileAt(Vector2 pos)
	{
		if (!g_singlestartpushwalls) { return; }

		MapHandler this = MapHandler.Get();
		if (!this || !this.curmap) { return false; }

		pos = ParsedMap.CoordsToGrid(pos);

		if (pos.x < 0 || pos.y < 0 || pos.x > 63 || pos.y > 63) { return false; }

		this.curmap.planes[0][int(pos.x)][int(pos.y)] = 0;
		this.curmap.planes[1][int(pos.x)][int(pos.y)] = 0;
		this.curmap.planes[2][int(pos.x)][int(pos.y)] = 0;

		return true;
	}

	static void ActivateFloorCode(Vector2 pos, Actor activator)
	{
		MapHandler this = MapHandler.Get();
		if (!this) { return; }

		int floor = MapHandler.TileAt(pos);

		if (floor > 0x65 && this.activatedfloors.Find(floor) == this.activatedfloors.Size())
		{
			this.activatedfloors.Push(floor);

			let it = level.CreateActorIterator(floor, "Actor");
			Actor mo;

			while (mo = Actor(it.Next()))
			{
				if (!mo.bIsMonster || mo.bDormant || !mo.bShootable || mo.health <= 0 || mo.bAmbush) { continue; }

				let c = ClassicBase(mo);
				if (c)
				{
					if (c.bActive) { continue; }
					else { c.bActive = true; }
				}

				mo.target = activator;
				mo.SetState(mo.SeeState);
				mo.vel *= 0;

				if (mo.bBoss || mo.bFullVolSee)
				{
					mo.A_StartSound(mo.SeeSound, CHAN_VOICE, CHANF_DEFAULT, 1.0, ATTN_NONE);
				}
				else
				{
					mo.A_StartSound(mo.SeeSound, CHAN_VOICE, CHANF_DEFAULT, 1.0, ATTN_NORM);
				}
			}
		}
	}
}

class ActorMap
{
	int index;
	String classname[4];
	int skill;
	int angle;

	static ActorMap Add(int index, String entry)
	{
		entry = ZScriptTools.Trim(entry);
		if (!entry.length()) { return null; }

		Array<String> values;

		entry.split(values, ",");
		if (!values.Size()) { values.Push(entry); }

		ActorMap m = New("ActorMap");
		m.index = index;
		m.classname[0] = values[0];
		m.classname[1] = (values.Size() > 1 && values[1].length()) ? values[1] : m.classname[0];
		m.classname[2] = (values.Size() > 2 && values[2].length()) ? values[2] : m.classname[1];
		m.classname[3] = (values.Size() > 3 && values[3].length()) ? values[3] : m.classname[2];
		m.skill = values.Size() > 4 ? values[4].ToInt() : 0;
		m.angle = values.Size() > 5 ? values[5].ToInt() : 270;

		return m;
	}

	static ActorMap GetActor(Array<ActorMap> actormaps, int index, int skill)
	{
		for (int m = 0; m < actormaps.Size(); m++)
		{
			if (actormaps[m].index == index && actormaps[m].skill <= skill)
			{
				return actormaps[m];
			}
		}

		return null;
	}

	Class<Actor> GetSpawnClass(int which = -1)
	{
		return classname[clamp(which > -1 ? which : g_sod, 0, 3)];
	}
}

class ParsedMap
{
	String mapname;
	DataFile datafile;
	LevelInfo info;
	int mapnum;
	int gametype;
	String signature;
	int width;
	int height;
	int planes[3][64][64];
	Array<Sector> voidspace;
	bool noclip;
	Vector2 startspot;

	int TileAt(Vector2 pos)
	{
		if (pos.x < 0 || pos.y < 0 || pos.x > 63 || pos.y > 63) { return -1; } // Map edges return an invalid tile, but not "nothing"
		return planes[0][int(pos.x)][int(pos.y)];
	}

	int ActorAt(Vector2 pos)
	{
		if (pos.x < 0 || pos.y < 0 || pos.x > 63 || pos.y > 63) { return 0; }
		return planes[1][int(pos.x)][int(pos.y)];
	}

	static Vector2 CoordsToGrid(Vector2 coords)
	{
		return (int(floor(coords.x / 64)) + 32, int(floor(-coords.y / 64)) + 32);
	}

	static Vector2 GridToCoords(Vector2 coords)
	{
		return ((coords.x - 32) * 64 + 32, -(coords.y - 32) * 64 - 32);
	}

	void PrintPlane(int plane = 0)
	{
		console.printf("%s - Plane %i", mapname, plane);
		for (int i = 0; i < 64; i++)
		{
			console.printf("%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x", 
			planes[plane][0][i], planes[plane][1][i], planes[plane][2][i], planes[plane][3][i], planes[plane][4][i], planes[plane][5][i], planes[plane][6][i], planes[plane][7][i],
			planes[plane][8][i], planes[plane][9][i], planes[plane][10][i], planes[plane][11][i], planes[plane][12][i], planes[plane][13][i], planes[plane][14][i], planes[plane][15][i],
			planes[plane][16][i], planes[plane][17][i], planes[plane][18][i], planes[plane][19][i], planes[plane][20][i], planes[plane][21][i], planes[plane][22][i], planes[plane][23][i],
			planes[plane][24][i], planes[plane][25][i], planes[plane][26][i], planes[plane][27][i], planes[plane][28][i], planes[plane][29][i], planes[plane][30][i], planes[plane][31][i],
			planes[plane][32][i], planes[plane][33][i], planes[plane][34][i], planes[plane][35][i], planes[plane][36][i], planes[plane][37][i], planes[plane][38][i], planes[plane][39][i],
			planes[plane][40][i], planes[plane][41][i], planes[plane][42][i], planes[plane][43][i], planes[plane][44][i], planes[plane][45][i], planes[plane][46][i], planes[plane][47][i],
			planes[plane][48][i], planes[plane][49][i], planes[plane][50][i], planes[plane][51][i], planes[plane][52][i], planes[plane][53][i], planes[plane][54][i], planes[plane][55][i],
			planes[plane][56][i], planes[plane][57][i], planes[plane][58][i], planes[plane][59][i], planes[plane][60][i], planes[plane][61][i], planes[plane][62][i], planes[plane][63][i]);
		}
	}

	void ExpandData(int plane, String planedata, int encoding = 0xABCD)
	{
		Array<int> expanded;

		if (planedata.length() != 8192)
		{
			CarmackExpand(planedata, expanded);
		}

		RLEWExpand(planedata, encoding, expanded);

		for (int y = 0; y < height; y++)
		{
			for (int x = 0; x < width; x++)
			{
				int index = y * 2 * width + x * 2;

				if (index < expanded.size()) { planes[plane][x][y] = expanded[index + 1] * 0x100 + expanded[index]; }
			}
		}
	}

	int CarmackExpand(String input, in out Array<int> outputbytes)
	{
		Array<int> inputbytes;
		int offset = 0;

		for (int i = 0; i < input.length(); i++) { inputbytes.Push(input.ByteAt(i)); }

		int length = inputbytes[offset + 1] * 0x100 + inputbytes[offset];
		offset += 2;

		while (offset < inputbytes.Size())
		{
			if (inputbytes[offset + 1] == 0xA7)
			{
				int count = inputbytes[offset];
				int dist = inputbytes[offset + 2];

				if (count == 0)
				{
					outputbytes.Push(dist);
					outputbytes.Push(0xA7);
				}
				else
				{
					int start = outputbytes.Size() - dist * 2;
					for (int o = start; o < start + count * 2; o++) { outputbytes.Push(outputbytes[o]); }
				}

				offset += 3;
			}
			else if (inputbytes[offset + 1] == 0xA8)
			{
				int count = inputbytes[offset];

				if (count == 0)
				{
					outputbytes.Push(inputbytes[offset + 2]);
					outputbytes.Push(0xA8);

					offset += 3;
				}
				else
				{
					int dist = inputbytes[offset + 3] * 0x100 + inputbytes[offset + 2];
					int start = dist * 2;

					for (int o = start; o < start + count * 2; o++) { outputbytes.Push(outputbytes[o]); }

					offset += 4;
				}
			}
			else
			{
				outputbytes.Push(inputbytes[offset]);
				outputbytes.Push(inputbytes[offset + 1]);

				offset += 2;
			}
		}

		return length;
	}

	int RLEWExpand(String input, int encoding, in out Array<int> outputbytes)
	{
		Array<int> inputbytes;
		int offset = 0;

		if (!outputbytes.Size())
		{
			for (int i = 0; i < input.length(); i++) { inputbytes.Push(input.ByteAt(i)); }
		}
		else
		{
			for (int i = 0; i < outputbytes.Size(); i++) { inputbytes.Push(outputbytes[i]); }
			outputbytes.Clear();
		}

		int length = inputbytes[offset + 1] * 0x100 + inputbytes[offset];
		offset += 2;

		while (offset < inputbytes.Size())
		{
			int value = inputbytes[offset + 1] * 0x100 + inputbytes[offset];

			if (value == encoding)
			{
				int count = inputbytes[offset + 3] * 0x100 + inputbytes[offset + 2];

				while (count--)
				{
					outputbytes.Push(inputbytes[offset + 4]);
					outputbytes.Push(inputbytes[offset + 5]);
				}

				offset += 6;
			}
			else
			{
				outputbytes.Push(inputbytes[offset]);
				outputbytes.Push(inputbytes[offset + 1]);

				offset += 2;
			}
		}

		return length;
	}

	play void Initialize()
	{
		if (level.mapname ~== "Level")
		{
			MapHandler handler = MapHandler.Get();

			voidspace.Clear();
			noclip = false;

			if (gametype > -1)
			{
				CVar sodvar = CVar.FindCVar("g_sod");
				if (sodvar) { sodvar.SetInt(gametype); }
			}

			TextureID nulltex = TexMan.CheckForTexture("-", TexMan.Type_Any);
			TextureID blanktex = TexMan.CheckForTexture("BLACK", TexMan.Type_Any);
			
			for (int s = 0; s < level.sectors.Size(); s++)
			{
				Sector sec = level.sectors[s];

				// If this sector is out of range, continue
				if (abs(sec.centerspot.x) > 2048 || abs(sec.centerspot.y) > 2048) { continue; }

				// Clear any previously spawned actors
				Actor thing = sec.thinglist;
				while (thing != null)
				{
					if (!(thing is "PlayerPawn")) { thing.Destroy(); }
					thing = (thing == sec.thinglist) ? null : thing.snext;
				}

				Vector2 pos = CoordsToGrid(sec.centerspot);

				int t = TileAt(pos);
				int a = ActorAt(pos);

				if (a >= 0x13 && a <= 0x16)
				{
					startspot = sec.centerspot;
					double angle = 90 - (a - 0x13) * 90;

					if (deathmatch)
					{
						players[0].mo.SetOrigin((GetNextSpot(startspot, angle, 0, deathmatch), 0), false);
					}
					else
					{
						// Move player 1 into start spot; the rest are handled in event handler
						players[0].mo.SetOrigin((startspot, 0), false);
					}

					players[0].mo.angle = angle;
				}

				// Build the wall structure
				if ((t > 0 && t < 0x5A) && (a == 0 || (a > 0x59 && a < 0x62)))
				{
					// Collapse the sector height
					sec.MoveFloor(256, sec.floorplane.PointToDist(sec.centerspot, sec.CenterFloor() + 64), 0, 1, 0, true);

					// Make lines blocking and set textures
					for (int l = 0; l < sec.lines.Size(); l++)
					{
						let ln = sec.lines[l];

						ln.flags &= ~Line.ML_TWOSIDED;
						ln.flags |= Line.ML_BLOCKING | Line.ML_BLOCKSIGHT | Line.ML_SOUNDBLOCK;

						TextureID tex = GetTexture(pos, ln);

						for (int s = 0; s < 2; s++)
						{
							if (ln.sidedef[s] && ln.sidedef[s].sector != sec)
							{
								ln.sidedef[s].SetTexture(side.mid, tex);
								ln.sidedef[s].SetTexture(side.bottom, tex);
							}
						}
					}

					// Set the floor texture to the wall texture so they show up on the automap
					sec.SetTexture(Sector.floor, GetTexture(pos));
				}

				// Spawn actors
				if (a > 0)
				{
					Actor mo;
					ActorMap am = ActorMap.GetActor(handler.actormapping, a, G_SkillPropertyInt(SKILLP_ACSReturn) + 1);

					if (am)
					{
						// Spawn the actor
						Class<Actor> spawnclass = am.GetSpawnClass(gametype);
						mo = Actor.Spawn(spawnclass, (sec.centerspot, 0));
						if (mo)
						{
							// Align the actor
							mo.angle = am.angle;
							
							// Assign a TID matching the floor code for alerting reasons
							// (Recreate's Wolf's ability to alert actors elsewhere 
							// in the map if they share the same floor code)
							if (t == 0x6A)  // Deaf Guard Floor Code
							{
								mo.bAmbush = true;

								// Look at nearby tiles to find the closest floor code
								t = TileAt(pos + (1, 0));
								if (t < 0x6B) { t = TileAt(pos - (1, 0)); }
								if (t < 0x6B) { t = TileAt(pos + (0, 1)); }
								if (t < 0x6B) { t = TileAt(pos - (0, 1)); }
								if (t < 0x6B) { t = 0; } // Fall back to not assigning a TID
							}
							
							mo.ChangeTID(t);
						}
					}
				}
			}

			// Clean up display of collapse sectors on the automap
			for (int s = 0; s < level.sectors.Size(); s++)
			{
				let sec = level.sectors[s];

				// If this sector is out of range, continue
				if (abs(sec.centerspot.x) > 2048 || abs(sec.centerspot.y) > 2048) { continue; }

				// Don't draw lines between sectors that are collapsed
				int edges = 0;
				for (int l = 0; l < sec.lines.Size(); l++)
				{
					let ln = sec.lines[l];
					int solid = 0;

					for (int s = 0; s < 2; s++)
					{
						if (!ln.sidedef[s] || ln.sidedef[s].sector.CenterCeiling() - ln.sidedef[s].sector.CenterFloor() == 0) { solid++; }
					}

					if (solid > 1)
					{
						ln.flags |= Line.ML_DONTDRAW;
						edges++;
					}
				}

				Vector2 pos = CoordsToGrid(sec.centerspot);

				bool accessible = (ActorAt(pos + (1, 0)) || ActorAt(pos - (1, 0)) || ActorAt(pos + (0, 1)) || ActorAt(pos - (0, 1)));

				// Set the floor and ceiling for collapsed sectors to "-", and 
				// set the wall textures to solid so they block automap sight traversal
				if (edges == sec.lines.Size() && !accessible)
				{
					sec.SetTexture(Sector.floor, nulltex);
					sec.SetTexture(Sector.ceiling, nulltex);

					for (int l = 0; l < sec.lines.Size(); l++)
					{
						let ln = sec.lines[l];
						for (int s = 0; s < 2; s++)
						{
							if (ln.sidedef[s])
							{
								ln.sidedef[s].SetTexture(side.top, blanktex);
								ln.sidedef[s].SetTexture(side.bottom, blanktex);
							}
						}
					}

					voidspace.Push(sec);
				}
				else
				{
					for (int l = 0; l < sec.lines.Size(); l++)
					{
						let ln = sec.lines[l];

						for (int s = 0; s < 2; s++)
						{
							if (ln.sidedef[s])
							{
								ln.sidedef[s].SetTexture(side.top, nulltex);
								ln.sidedef[s].SetTexture(side.bottom, nulltex);
							}
						}
					}
				}

				int t = TileAt(pos);
				int a = ActorAt(pos);

				// Handle texturing of doors and door frames
				if ((t >= 0x5A && t <= 0x65) || a == 0x62)
				{
					PolyobjectHandle door = PolyobjectHandle.FindPolyobjAt(sec.CenterSpot);
					if (door)
					{
						door.Lines.Push(door.StartLine);

						if (door.StartLine.special != Polyobj_ExplicitLine)
						{
							// Find all lines that belong to this polyobject
							Vertex start = door.StartLine.v1;
							Vertex current = door.StartLine.v2;
							int count = 0;

							door.Lines.Push(door.StartLine);

							while (current.Index() != start.Index() && count < level.lines.Size())
							{
								for (int l = 0; l < level.lines.Size(); l++)
								{
									count++;
									let ln = level.lines[l];
									if (ln.v1 == current)
									{
										if (door.Lines.Find(ln) == door.Lines.Size()) { door.Lines.Push(ln); }
										current = ln.v2;
										count = 0;
										break;
									}
									if (count > level.lines.Size()) { break; }
								}
							}
						}
					}

					for (int l = 0; l < sec.lines.Size(); l++)
					{
						let ln = sec.lines[l];

						// Block sounds by default
						if (ln.flags & Line.ML_TWOSIDED) { ln.flags |= Line.ML_SOUNDBLOCK; }

						// If this is a standard door entry, set up activation and flags
						if (ln.flags & Line.ML_TWOSIDED && ln.frontsector.CenterFloor() == ln.backsector.CenterFloor())
						{
							if (a != 0x62) // Don't set activation lines for secret doors
							{
								ln.flags |= Line.ML_BLOCK_PLAYERS | Line.ML_DONTDRAW; // Block players by default, and don't draw on the automap

								if (door)
								{
									// Set two-sided lines to open/close the door so that it
									// can be closed even without directly using the polyobject
									ln.special = Polyobj_DoorSlide;
									ln.args[0] = door.PolyobjectNum;
									ln.args[2] = (t % 2 == 0) ? 192 : 0;
									ln.activation = SPAC_Use | SPAC_UseBack | SPAC_UseThrough;
									ln.flags |= Line.ML_REPEAT_SPECIAL;

									if (t >= 0x5C && t <= 0x63)
									{
										ln.locknumber = 60 + (t - 0x5C) / 2;
									}
								}
							}
						}

						// If this line borders a secret door, continue
						if (t < 0x5A || t > 0x65 && a == 0x62) { continue; }

						// If this line is an entryway, continue
						if (ln.flags & Line.ML_TWOSIDED)
						{
							if (t % 2 == 1 && ln.delta.x) { continue; }
							if (t % 2 == 0 && ln.delta.y) { continue; }
						}

						// Don't add door frames if Deaf Guard tiles meet the threshhold
						if (CheckDoorTiles(pos)) { continue; }

						// Set door frame textures on the sides
						for (int s = 0; s < 2; s++)
						{
							if (ln.sidedef[s] && ln.sidedef[s].sector == sec)
							{
								ln.sidedef[s].SetTexture(side.mid, GetTileTexture(0x41, pos, ln));
							}
						}
					}

					if (door)
					{
						for (int l = 0; l < door.Lines.Size(); l++)
						{
							let ln = door.lines[l];

							if (ln.special == 8 || a == 0x62)
							{
								TextureID tex;
								bool locked = false;

								if (t >= 0x5C && t <= 0x63)
								{
									locked = true;
									if (ln.special == 8) { ln.locknumber = 60 + (t - 0x5C) / 2; }

									// Set the doors to colored variants if the CVar is set
									if (g_usedoorkeycolors)
									{
										String texpath = String.Format("WLF%iLK%i", gametype > 0 ? gametype : max(0, g_sod), ln.locknumber - 59);
										if (ln.delta.x) { texpath = String.Format("%sG", texpath); }
										else { texpath = String.Format("%sF", texpath); }

										tex = TexMan.CheckForTexture(texpath, TexMan.Type_Any);
									}
								}

								// Set door textures
								for (int s = 0; s < 2; s++)
								{
									if (ln.sidedef[s])
									{
										if (locked && tex.IsValid()) { ln.sidedef[s].SetTexture(side.mid, tex); }
										else { ln.sidedef[s].SetTexture(side.mid, GetTexture(pos, ln)); }
									}
								}
							}
						}
					}

					// If this was a secret door, flag it as a secret and set the floor texture for the automap
					if (a == 0x62)
					{
						if (t < 0x5A)
						{
							sec.flags |= Sector.SECF_SECRET | Sector.SECF_WASSECRET;
							Level.total_secrets++;

							sec.SetTexture(Sector.floor, GetTexture(pos));
						}
					}
				}
				else if (t == 0x15) // Elevator switch
				{
					bool secret = (TileAt(pos + (1, 0)) == 0x6B || TileAt(pos - (1, 0)) == 0x6B);
					for (int l = 0; l < sec.lines.Size(); l++)
					{
						let ln = sec.lines[l];
						if (ln.delta.x || (ln.frontsector && ln.backsector && ln.frontsector.CenterFloor() == ln.backsector.CenterFloor())) { continue; }

						ln.special = 80;
						ln.args[0] = 10;
						ln.args[2] = secret ? 10 : 0;

						ln.activation = SPAC_Use | SPAC_UseBack;
					}
				}
				else if (a == 0x63) // Walkover exit trigger
				{
					for (int l = 0; l < sec.lines.Size(); l++)
					{
						let ln = sec.lines[l];

						// If this line is a wall, continue;
						if (!(ln.flags & Line.ML_TWOSIDED)) { continue; }

						ln.special = 80;
						ln.args[0] = 4;
						ln.args[2] = 1;

						ln.activation = SPAC_Cross;
					}
				}

				// Set wall textures for walls with things spawned inside of them
				if (t > 0 && t < 0x5A && (a > 0 && a != 0x62))
				{
					// Make lines blocking and set textures
					for (int l = 0; l < sec.lines.Size(); l++)
					{
						let ln = sec.lines[l];

						ln.flags |= Line.ML_BLOCKSIGHT | Line.ML_SOUNDBLOCK;

						if (ln.frontsector.CenterFloor() == ln.backsector.CenterFloor())
						{
							TextureID tex = GetTexture(pos, ln);
							for (int s = 0; s < 2; s++)
							{
								if (ln.sidedef[s])
								{
									if (ln.sidedef[s].sector != sec)
									{
										ln.sidedef[s].SetTexture(side.mid, tex);
										ln.sidedef[s].SetTexture(side.bottom, tex);
									}
								}
							}	
						}
						else
						{
							Sector texsec = (ln.frontsector == sec) ? ln.backsector : ln.frontsector;
							Vector2 texpos = (texsec ? texsec.CenterSpot : (-4096, 4096));
							texpos = ParsedMap.CoordsToGrid(texpos);
							TextureID tex = GetTexture(texpos, ln);

							for (int s = 0; s < 2; s++)
							{
								if (ln.sidedef[s])
								{
									if (ln.sidedef[s].sector == sec)
									{
										ln.sidedef[s].SetTexture(side.mid, tex);
										ln.sidedef[s].SetTexture(side.bottom, tex);
									}
								}
							}
						}
					}
				}
			}
		}
	}

	LevelInfo GetInfo()
	{
		for (int i = 0; i < LevelInfo.GetLevelInfoCount(); i++)
		{
			LevelInfo info = LevelInfo.GetLevelInfo(i);
			if (info.levelnum == mapnum || info.mapname ~== mapname) { return info; }
		}

		return null;
	}

	TextureID GetTexture(Vector2 pos, Line ln = null)
	{
		int t = TileAt(pos);

		return GetTileTexture(t, pos, ln);
	}

	TextureID GetTileTexture(int t, Vector2 pos, Line ln = null)
	{
		int game = gametype;
		if (game < 0) { game = max(0, g_sod); }

		// Special handling for doors
		if (t >= 0x5A && t <= 0x6A || t == 0x41)
		{
			// Use standard Wolf3D door/doorframe images in SoD; offset as appropriate for mission packs
			game = game <= 1 ? 0 : game;

			if (t == 0x41)  { t = game == 0 ? 0x33 : 0x41; }
			else if (t >= 0x5A && t <= 0x5B) { t = game == 0 ? 0x32 : 0x40; }
			else if (t >= 0x5C && t <= 0x63) { t = game == 0 ? 0x35 : 0x43; }
			else if (t >= 0x64 && t <= 0x65) { t = game == 0 ? 0x34 : 0x42; }
		}

		int tiletex = (!ln || ln.delta.x) ? (t - 1) * 2 : (t - 1) * 2 + 1;
		if (tiletex == 42) { tiletex = 40; }
		if (!ln && tiletex == 40 && (TileAt(pos + (1, 0)) > 0x65 || TileAt(pos - (1, 0)) > 0x65)) { tiletex = 41; }

		TextureID tex;

		while (game > -1 && !tex.IsValid())
		{
			// Note: SD3 texture order is mapped onto SD2 textures via TEXTURES definitions
			String texpath = String.Format("Patches/Walls/Wall%i%03i.png", game, tiletex);
			tex = TexMan.CheckForTexture(texpath, TexMan.Type_Any);

			if (!tex.IsValid()) { game--; }
		}

		if (!tex.IsValid()) { tex = TexMan.CheckForTexture("Patches/Walls/Wall0000.png", TexMan.Type_Any); }

		return tex;
	}

	Vector2 GetNextSpot(Vector2 pos, double angle, int iter = 0, bool random = false)
	{
		// Randomize spawn locations across the map
		if (random)
		{
			bool blocked = true;
			while (blocked)
			{
				int column = Random[dmstart](1, 63); // Random column
				int row = Random[dmstart](1, 63); // Random row
				
				for (int y = row; y < 64; y++) // Look for an empty tile
				{
					Vector2 gridpos = (column, Random[dmstart](0, 1) ? y : 63 - y); // Start from the botton randomly
					int t = TileAt(gridpos);

					bool blocked = (t != 0 && t < 0x6A); // Walls keep you from spawning
					if (!blocked) { blocked = !!FindBlockingActor(GridToCoords(gridpos)); } // And so do blocking actors

					if (!blocked) { return GridToCoords(gridpos); } // But if you're not blocked, spawn here
					// Keep looking in this column
				}
				// Otherwise try again with a new random spot
			}
		}

		// Otherwise, spawn in a 3x3 grid pattern in alignment with the player start
		Vector2 offset = (iter / 3,  (iter % 3) - 1);
		offset = Actor.RotateVector(offset, angle);

		Vector2 gridpos = CoordsToGrid(pos) - offset;

		if (gridpos.x > 64 || gridpos.y > 64 || gridpos.x < 0 || gridpos.y < 0) { return pos; }

		int t = TileAt(gridpos);

		bool blocked = (t != 0 && t < 0x6A);
		if (!blocked) { blocked = !!FindBlockingActor(pos + offset * 64); }
		if (blocked) { return GetNextSpot(pos, angle, ++iter); }
		
		return pos + offset * 64;
	}

	Actor FindBlockingActor(Vector2 spot, int dist = 32)
	{
		BlockThingsIterator it = BlockThingsIterator.CreateFromPos(spot.x, spot.y, 0, 0, dist, false);
		while (it.Next())
		{
			if (it.thing.bSolid && Level.Vec2Diff(spot, it.thing.pos.xy).length() < dist) { return it.thing; }
		}

		return null;
	}

	// Check for tiles on either side of doors
	// Check against g_deafguardoors CVar amount if checking for Deaf Guard tiles (default)
	int CheckDoorTiles(Vector2 spot, int tile = 0x6A, int tile2 = -1)
	{ 
		if (tile == 0x6A && g_deafguarddoors == 0) { return 0; }

		int t = TileAt(spot);
		int a = ActorAt(spot);
		if (t < 0x5A || t > 0x65) { return 0; }

		int t1, t2;
		int tilecount = 0;

		if (t % 2 == 0)
		{
			t1 = TileAt(spot - (1, 0));
			t2 = TileAt(spot + (1, 0));
		}
		else
		{
			t1 = TileAt(spot - (0, 1));
			t2 = TileAt(spot + (0, 1));
		}

		tilecount += (t1 == tile && (tile2 < 0 ? 1 : t2 == tile2)) + (t2 == tile && (tile2 < 0 ? 1 : t1 == tile2));

		if (tile != 0x6A) { return tilecount; }

		return !!(tilecount >= g_deafguarddoors);
	}

	int CountDoors(Vector2 pos)
	{
		int count = 0;

		for (int y = 0; y <= pos.y; y++)
		{
			for (int x = 0; x < 64; x++)
			{
				int t = TileAt((x, y));
				count += (t >= 0x5A && t <= 0x65);

				if (y == pos.y && x + 1 == pos.x) { break; }
			}
		}

		return count;
	}
}

class WolfMapParser
{
	Array<ParsedMap> maps;
	int gametype;
	int custommapcount;

	static void Parse(in out WolfMapParser parsedmaps, in out DataFile d)
	{
		int headlump = -1;
		int mapslump = -1;

		if (!parsedmaps) { parsedmaps = New("WolfMapParser"); }
		if (!d) { return; }

		if (d.headpath.length()) { headlump = Wads.CheckNumForFullName(d.headpath); }
		mapslump = Wads.CheckNumForFullName(d.path);

		if (mapslump == -1) { return; }

		String game = d.path.Mid(d.path.length() - 3);
		if (game ~== "WL1" || game ~== "WL3" || game ~== "WL6") { parsedmaps.gametype = 0; }
		else if (game ~== "SOD" || game ~== "SD1") { parsedmaps.gametype = 1; }
		else if (game ~== "SD2") { parsedmaps.gametype = 2; }
		else if (game ~== "SD3") { parsedmaps.gametype = 3; }
		else { parsedmaps.gametype = -1; } // Play as Wolf, but allow setting via CVar

		int encoding;
		Array<int> addresses;
		if (headlump > -1) { parsedmaps.ReadMapHead(Wads.ReadLump(headlump), encoding, addresses); }
		parsedmaps.ReadGameMaps(Wads.ReadLump(mapslump), encoding, addresses, d);
	}

	void ReadMapHead(String content, out int encoding, in out Array<int> addresses)
	{
		int offset = 0;
		[encoding, offset] = WolfMapParser.GetLittleEndian(content, 0, 2);

		while (offset < content.Length())
		{
			int address;
			[address, offset] = GetLittleEndian(content, offset, 4);

			addresses.Push(address);
		}
	}

	enum maptypes
	{
		GameMaps,
		Raw,
		RawWithHeader,
		FloEdit,
	};

	void ReadGameMaps(String content, int encoding, Array<int> addresses, Datafile d)
	{
		maptypes type = GameMaps;
		if (!addresses.Size())
		{
			int size = content.length();

			if (size == 16384)
			{ // Raw
				addresses.Push(8);
				type = Raw;
			}
			else if (size == 16393)
			{ // Raw
				addresses.Push(8);
				type = FloEdit;
			}
			else if (size == 16418 || size == 24610)
			{ // Raw with Header
				addresses.Push(8);
				type = RawWithHeader;
			}
			else
			{ // Invalid Format
				return;
			}
		}

		for (int a = 0; a < addresses.Size(); a++)
		{
			int offset = addresses[a];
			if (offset == 0) { continue; }

			ParsedMap newmap = New("ParsedMap");
			newmap.datafile = d;
			
			int planeoffsets[3];
			int planesizes[3];

			if (type > GameMaps)
			{
				// Set defaults for fallback
				newmap.width = 64;
				newmap.height = 64;
				newmap.mapname = "Custom Map";

				if (type == RawWithHeader)
				{
					newmap.signature = content.Left(8);
					planeoffsets[0] = 34;

					if (newmap.signature.left(3) ~== "WDC")
					{
						newmap.width = WolfMapParser.GetLittleEndian(content, 0x1E, 2);
						newmap.height = WolfMapParser.GetLittleEndian(content, 0x20, 2);
						newmap.mapname = content.Mid(0x0E, WolfMapParser.GetLittleEndian(content, 0x0C, 2));
					}
					else if(newmap.signature.left(2) ~== "CE") // ChaosEdit
					{
						newmap.width = content.ByteAt(0x0C) * 0x100 + content.ByteAt(0x0D);
						newmap.height = content.ByteAt(0x0E) * 0x100 + content.ByteAt(0x0F);
						newmap.mapname = content.Mid(0x12, content.ByteAt(0x10) * 0x100 + content.ByteAt(0x11));
					}
				}
				else if (type == FloEdit)
				{
					newmap.signature = content.Left(8);
					planeoffsets[0] = 9;
				}

				planeoffsets[1] = planeoffsets[0] + 8192;

				newmap.mapnum = 1000 + custommapcount++;

				for (int p = 0; p < 2; p++)
				{
					String plane = content.Mid(planeoffsets[p]);

					for (int y = 0; y < newmap.height; y++)
					{
						for (int x = 0; x < newmap.width; x++)
						{
							if (type == FloEdit)
							{
								int index = x * 2 * newmap.height + y * 2;
								newmap.planes[p][x][y] = WolfMapParser.GetLittleEndian(plane, index, 2);
							}
							else
							{
								int index = y * 2 * newmap.width + x * 2;
								newmap.planes[p][x][y] = WolfMapParser.GetLittleEndian(plane, index, 2);
							}
						}
					}
				}
			}
			else
			{
				[planeoffsets[0], offset] = WolfMapParser.GetLittleEndian(content, offset, 4);
				[planeoffsets[1], offset] = WolfMapParser.GetLittleEndian(content, offset, 4);
				[planeoffsets[2], offset] = WolfMapParser.GetLittleEndian(content, offset, 4);


				[planesizes[0], offset] = WolfMapParser.GetLittleEndian(content, offset, 2);
				[planesizes[1], offset] = WolfMapParser.GetLittleEndian(content, offset, 2);
				[planesizes[2], offset] = WolfMapParser.GetLittleEndian(content, offset, 2);

				[newmap.width, offset] = WolfMapParser.GetLittleEndian(content, offset, 2);
				[newmap.height, offset] = WolfMapParser.GetLittleEndian(content, offset, 2);

				newmap.mapname = content.Mid(offset, 16);
				offset += 16;
				newmap.signature = content.Mid(offset, 4);
				newmap.mapnum = gametype <= 0 ? (a / 10 + 1) * 100 + a % 10 + 1 : 600 + gametype * 100 + a + 1;

				for (int p = 0; p < 3; p++)
				{
					if (planesizes[p] <= 0) { continue; }
					newmap.ExpandData(p, content.mid(planeoffsets[p], planesizes[p]), encoding);
				}
			}
			
			newmap.gametype = gametype;
			newmap.info = newmap.GetInfo();

			d.maps.Push(newmap);
			maps.Push(newmap);
		}
	}

	ParsedMap GetMapData(String mapname, String datafile = "")
	{
		for (int m = maps.Size() - 1; m >= 0; m--)
		{
			if (maps[m].mapname ~== mapname && (!datafile.length() || maps[m].datafile.path ~== datafile)) { return maps[m]; }
		}

		for (int m = maps.Size() - 1; m >= 0; m--)
		{
			if (maps[m].mapname ~== mapname && maps[m].datafile.gametitle == "Custom Maps") { return maps[m]; }
		}

		return null;
	}

	ParsedMap GetMapDataByNumber(int mapnum, String datafile = "")
	{
		for (int m = 0; m < maps.Size(); m++)
		{
			if (maps[m].mapnum == mapnum && (!datafile.length() || maps[m].datafile.path ~== datafile)) { return maps[m]; }
		}

		return null;
	}

	static int, int GetLittleEndian(String input, int offset = 0, int count = 2)
	{
		int ret = 0;

		for (int b = count - 1; b >= 0; b--)
		{
			ret += int((0x100 ** b) * input.ByteAt(offset + b));
		}

		return ret, offset + count;
	}
}

class DataFile
{
	String gametitle;
	String path;
	String headpath;
	Array<ParsedMap> maps;

	static DataFile Find(in out Array<DataFile> datafiles, String title, String path, String headpath = "")
	{
		for (int i = 0; i < datafiles.Size(); i++)
		{
			if (
				(!headpath.length() && datafiles[i].gametitle == title) ||
				(datafiles[i].path ~== path && datafiles[i].headpath ~== headpath)
			)
			{
				return datafiles[i];
			}
		}

		let d = New("DataFile");

		if (!headpath.length())
		{
			d.gametitle = title;
		}
		else
		{
			d.path = path;
			d.headpath = headpath;

			String hash = MD5.hash(Wads.ReadLump(Wads.CheckNumForFullName(path)));

			if (hash == "30fecd7cce6bc70402651ec922d2da3d")
			{ d.gametitle = "Wolfenstein 3D Shareware"; }
			if (hash == "cec494930f3ac0545563cbd23cd611d6") // v1.2
			{ d.gametitle = "Wolfenstein 3D (Episodes 1-3)"; }
			else if (hash == "05ee51e9bc7d60f01a05334b1cfab1a5") // v1.1
			{ d.gametitle = "Wolfenstein 3D v1.1"; }
			else if (hash == "a15b04941937b7e136419a1e74e57e2f") // v1.2
			{ d.gametitle = "Wolfenstein 3D v1.2"; }
			else if (hash == "a4e73706e100dc0cadfb02d23de46481") // v1.4 / GoG / Steam
			{ d.gametitle = "Wolfenstein 3D v1.4"; }
			else if (hash == "4eb2f538aab6e4061dadbc3b73837762")
			{ d.gametitle = "Spear of Destiny Demo"; }
			else if (hash == "04f16534235b4b57fc379d5709f88f4a")
			{ d.gametitle = "Spear of Destiny"; }
			else if (hash == "fa5752c5b1e25ee5c4a9ec0e9d4013a9")
			{ d.gametitle = "Return to Danger"; }
			else if (hash == "4219d83568d770b1c6ac9c2d4d1dfb9e")
			{ d.gametitle = "The Ultimate Challenge"; }
			else if (hash == "29860b87c31348e163e10f8aa6f19295")
			{ d.gametitle = "The Ultimate Challenge (UAC Version)"; }
			else
			{
				String ext = path.Mid(path.length() - 3, 3);
				ext = ext.MakeLower();

				if (ext == "wl6") { d.gametitle = "Wolfenstein 3D (Modified)"; }
				else if (ext == "wl3") { d.gametitle = "Wolfenstein 3D (Episodes 1-3) (Modified)"; }
				else if (ext == "wl1") { d.gametitle = "Wolfenstein 3D Shareware (Modified)"; }
				else if (ext == "sdm") { d.gametitle = "Spear of Destiny Demo (Modified)"; }
				else if (ext == "sod" || ext == "sd1") { d.gametitle = "Spear of Destiny (Modified)"; }
				else if (ext == "sd2") { d.gametitle = "Return to Danger (Modified)"; }
				else if (ext == "sd3") { d.gametitle = "The Ultimate Challenge (Modified)"; }
			}
		}

		if (!d.gametitle.length()) { d.gametitle = path; }

		datafiles.Push(d);

		return d;
	}
}