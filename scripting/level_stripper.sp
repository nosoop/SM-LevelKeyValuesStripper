/**
 * Level KeyValues: Stripper
 * 
 * Drop-in replacement of Stripper:Source for Level KeyValues.
 */
#pragma semicolon 1
#include <sourcemod>

#include <regex>
#include <stocksoup/log_server>

#include <more_adt>
#include <level_keyvalues>

#pragma newdecls required

#define PLUGIN_VERSION "0.0.4"
public Plugin myinfo = {
	name = "Level KeyValues: Stripper",
	author = "nosoop",
	description = "Half-assed port of Stripper:Source to the Level KeyValues library.",
	version = PLUGIN_VERSION,
	url = "localhost"
}

// we can't use enums as there's currently a tag mismatch bug with using enums as array indices
#define BLOCK_GENERIC			0
#define BLOCK_MATCH				0
#define BLOCK_REPLACE			1
#define BLOCK_DELETE			2
#define BLOCK_INSERT			3
#define BLOCK_HANDLE_COUNT		4

enum StripperConfigMode {
	Mode_Filter,
	Mode_Add,
	Mode_Modify
};

enum StripperConfigSubMode {
	SubMode_None,
	SubMode_Match,
	SubMode_Replace,
	SubMode_Delete,
	SubMode_Insert
}

static StripperConfigMode s_ConfigMode;
static StripperConfigSubMode s_ConfigSubMode;

static StringMultiMap s_CurrentConfigBlock[BLOCK_HANDLE_COUNT];

char g_StripperDirectory[PLATFORM_MAX_PATH];

public void OnPluginStart() {
	// uses passed-in stripper path if it exists
	GetCommandLineParam("+stripper_path", g_StripperDirectory, sizeof(g_StripperDirectory),
			"addons/stripper");
	
	for (int i = BLOCK_GENERIC; i < sizeof(s_CurrentConfigBlock); i++) {
		s_CurrentConfigBlock[i] = new StringMultiMap();
	}
}

public void LevelEntity_OnAllEntitiesParsed() {
	char mapName[PLATFORM_MAX_PATH];
	GetCurrentMap(mapName, sizeof(mapName));
	
	static Regex s_KeyValueLine;
	
	if (!s_KeyValueLine) {
		// Pattern copied from alliedmodders/stripper-source/master/parser.cpp
		s_KeyValueLine = new Regex("\"([^\"]+)\"\\s+\"([^\"]+)\"");
	}
	
	// TODO parse global_filters.cfg
	
	char configPath[PLATFORM_MAX_PATH];
	Format(configPath, sizeof(configPath), "%s/maps/%s.cfg", g_StripperDirectory, mapName);
	
	if (!FileExists(configPath)) {
		return;
	}
	
	File config = OpenFile(configPath, "r");
	
	s_ConfigMode = Mode_Filter;
	s_ConfigSubMode = SubMode_None;
	
	int s_nNestedSection;
	
	char lineBuffer[255];
	while (config.ReadLine(lineBuffer, sizeof(lineBuffer))) {
		TrimString(lineBuffer);
		
		if (IsCommentLine(lineBuffer)) {
			continue;
		}
		
		switch(lineBuffer[0]) {
			case '{': {
				// only execute block on entering new main section
				if (!s_nNestedSection++) {
					// there's nothing here right now but we might add some diagnostics later
				}
			}
			case '}': {
				// only execute on leaving the last nested section
				if (!--s_nNestedSection) {
					// Stripper_EndSection();
					// LogServer("pushed block to list");
					switch (s_ConfigMode) {
						case Mode_Filter: {
							ApplyEntityFilter(s_CurrentConfigBlock[BLOCK_GENERIC]);
						}
						case Mode_Add: {
							// insert all keys into entity list
							LevelEntityKeyValues entity = view_as<LevelEntityKeyValues>(
									s_CurrentConfigBlock[BLOCK_GENERIC]);
							LevelEntityList.Push(entity);
						}
						case Mode_Modify: {
							ApplyEntityModify(s_CurrentConfigBlock[BLOCK_MATCH],
									s_CurrentConfigBlock[BLOCK_REPLACE],
									s_CurrentConfigBlock[BLOCK_DELETE],
									s_CurrentConfigBlock[BLOCK_INSERT]);
						}
					}
					
					for (int i = BLOCK_GENERIC; i < sizeof(s_CurrentConfigBlock); i++) {
						FreeConfigBlockHandles(s_CurrentConfigBlock[i]);
					}
				} else {
					// in subsection, clear submode
					if (s_ConfigSubMode != SubMode_None) {
						s_ConfigSubMode = SubMode_None;
					}
				}
			}
			default: {
				// https://github.com/alliedmodders/stripper-source/blob/a8da22305e0fd4fb846ad0270678980c459af6ef/parser.cpp#L524
				if (s_KeyValueLine.Match(lineBuffer) > 0) {
					char key[128], value[128];
					s_KeyValueLine.GetSubString(1, key, sizeof(key));
					s_KeyValueLine.GetSubString(2, value, sizeof(value));
					
					Stripper_KeyValue(key, value);
				} else if (StrEqual(lineBuffer, "filter:") || StrEqual(lineBuffer, "remove:")) {
					s_ConfigMode = Mode_Filter;
				} else if (StrEqual(lineBuffer, "add:")) {
					s_ConfigMode = Mode_Add;
				} else if (StrEqual(lineBuffer, "modify:")) {
					s_ConfigMode = Mode_Modify;
					s_ConfigSubMode = SubMode_None;
				} else if (s_ConfigMode == Mode_Modify) {
					if (StrEqual(lineBuffer, "match:")) {
						s_ConfigSubMode = SubMode_Match;
					} else if (StrEqual(lineBuffer, "replace:")) {
						s_ConfigSubMode = SubMode_Replace;
					} else if (StrEqual(lineBuffer, "delete:")) {
						s_ConfigSubMode = SubMode_Delete;
					} else if (StrEqual(lineBuffer, "insert:")) {
						s_ConfigSubMode = SubMode_Insert;
					}
				}
				// else it's an invalid line, ignore
			}
		}
	}
	delete config;
	
	for (int i = BLOCK_GENERIC; i < sizeof(s_CurrentConfigBlock); i++) {
		FreeConfigBlockHandles(s_CurrentConfigBlock[i]);
	}
	
	if (s_nNestedSection) {
		LogError("malformed config (ended at nesting level %d)", s_nNestedSection);
	}
}

bool IsCommentLine(const char[] lineBuffer) {
	return !lineBuffer[0] || strncmp(lineBuffer, "//", 2) == 0 || lineBuffer[0] == '#'
			|| lineBuffer[0] == ';';
}

void Stripper_KeyValue(const char[] key, const char[] value) {
	LogServer("wrote mode KV %d / %d -> %s / %s", s_ConfigMode, s_ConfigSubMode,
							key, value);
	
	int entry = BLOCK_GENERIC;
	if (s_ConfigMode == Mode_Modify) {
		switch (s_ConfigSubMode) {
			case SubMode_Match:   { entry = BLOCK_MATCH;   }
			case SubMode_Replace: { entry = BLOCK_REPLACE; }
			case SubMode_Delete:  { entry = BLOCK_DELETE;  }
			case SubMode_Insert:  { entry = BLOCK_INSERT;  }
		}
	}
	
	bool bAllowRegex;
	switch (s_ConfigMode) {
		case Mode_Filter: {
			bAllowRegex = true;
		}
		case Mode_Modify: {
			bAllowRegex = (s_ConfigSubMode == SubMode_Match || s_ConfigSubMode == SubMode_Delete);
		}
	}
	
	if (bAllowRegex && value[0] == '/' && value[strlen(value) - 1] == '/') {
		char exprBuffer[256];
		strcopy(exprBuffer, sizeof(exprBuffer), value[1]);
		exprBuffer[strlen(exprBuffer) - 1] = '\0';
		Regex expr = new Regex(exprBuffer);
		
		s_CurrentConfigBlock[entry].AddValue(key, expr);
		LogServer("created regex handle for expression %s", exprBuffer);
	} else {
		s_CurrentConfigBlock[entry].AddString(key, value);
	}
}

/**
 * Performs a filter operation, removing entities that match the input filter map.
 */
void ApplyEntityFilter(StringMultiMap filterKeys) {
	for (int i = 0; i < LevelEntityList.Length();) {
		LevelEntityKeyValues entity = LevelEntityList.Get(i);
		
		bool match = LevelEntityContainsMatch(entity, filterKeys);
		
		delete entity;
		
		if (match) {
			LogServer("Removed matching entity");
			LevelEntityList.Erase(i);
		} else {
			i++;
		}
	}
}

void ApplyEntityModify(StringMultiMap matchKeys, StringMultiMap replaceKeys = null,
		StringMultiMap deleteKeys = null, StringMultiMap insertKeys = null) {
	if (!replaceKeys && !deleteKeys && !insertKeys) {
		return;
	}
	
	char key[256], value[256];
	for (int i = 0; i < LevelEntityList.Length(); i++) {
		LevelEntityKeyValues entity = LevelEntityList.Get(i);
		
		if (LevelEntityContainsMatch(entity, matchKeys)) {
			// if key exists, remove all copies and insert a replacement
			if (replaceKeys) {
				StringMultiMapIterator replaceIter = replaceKeys.GetIterator();
				while (replaceIter.Next()) {
					replaceIter.GetKey(key, sizeof(key));
					if (entity.GetString(key, value, sizeof(value))) {
						entity.Remove(key);
						replaceIter.GetString(value, sizeof(value));
						
						entity.AddString(key, value);
					}
				}
				delete replaceIter;
			}
			
			// delete specified matching key / value
			if (deleteKeys) {
				StringMultiMapIterator removeIter = deleteKeys.GetIterator();
				while (removeIter.Next()) {
					removeIter.GetKey(key, sizeof(key));
					removeIter.GetString(value, sizeof(value));
					
					StringMultiMapIterator entIter = entity.GetIterator();
					char entKey[256], entValue[256];
					while (entIter.Next()) {
						entIter.GetKey(entKey, sizeof(entKey));
						if (!StrEqual(key, entKey)) {
							continue;
						}
						
						entIter.GetString(entValue, sizeof(entValue));
						if (StrEqual(entValue, value)) {
							entIter.Remove();
						}
					}
					delete entIter;
				}
				delete removeIter;
			}
			
			if (insertKeys) {
				StringMultiMapIterator insertIter = insertKeys.GetIterator();
				while (insertIter.Next()) {
					insertIter.GetKey(key, sizeof(key));
					insertIter.GetString(value, sizeof(value));
					
					entity.AddString(key, value);
				}
				delete insertIter;
			}
		}
		delete entity;
	}
}

/**
 * Returns true if all entries in `search` correspond to a key / value in `entity`.
 */
bool LevelEntityContainsMatch(LevelEntityKeyValues entity, StringMultiMap search) {
	char key[256], value[256];
	Regex expr = null;
	
	StringMultiMapIterator searchIter = search.GetIterator();
	
	// break if any of the entries don't match
	bool match = true;
	while (searchIter.Next()) {
		searchIter.GetKey(key, sizeof(key));
		
		// perform match -- either it's a fixed string or a regex handle
		if (searchIter.GetString(value, sizeof(value)) && !LevelEntityHasMatchingKeyValue(entity, key, value)) {
			match = false;
		} else if (searchIter.GetValue(expr) && !LevelEntityHasMatchingRegex(entity, key, expr)) {
			match = false;
		}
		
		if (!match) {
			break;
		}
	}
	
	delete searchIter;
	
	return match;
}

/**
 * Returns true if `entity` contains exact match of key / value.
 */
bool LevelEntityHasMatchingKeyValue(LevelEntityKeyValues entity, const char[] key, const char[] value) {
	bool result;
	char valueBuffer[256];
	LevelEntityKeyValuesIterator iter = entity.GetKeyIterator(key);
	while (iter.Next()) {
		if (iter.GetString(valueBuffer, sizeof(valueBuffer)) && StrEqual(valueBuffer, value)) {
			result = true;
			break;
		}
	}
	delete iter;
	
	return result;
}

/**
 * Returns true if `entity` contains a key and a value that is matched by the given regular
 * expression.
 */
bool LevelEntityHasMatchingRegex(LevelEntityKeyValues entity, const char[] key, Regex expr) {
	bool result;
	char valueBuffer[256];
	StringMultiMapIterator iter = entity.GetKeyIterator(key);
	while (iter.Next()) {
		if (iter.GetString(valueBuffer, sizeof(valueBuffer)) && expr.Match(valueBuffer) > 0) {
			LogServer("found regex match");
			result = true;
			break;
		}
	}
	delete iter;
	
	return result;
}

/**
 * Free up handles stored in the config block.  Any non-string values must be handles.
 */
void FreeConfigBlockHandles(StringMultiMap map) {
	StringMultiMapIterator iter = map.GetIterator();
	Regex expr;
	while (iter.Next()) {
		if (iter.GetValue(expr)) {
			delete expr;
		}
	}
	delete iter;
	
	map.Clear();
}
