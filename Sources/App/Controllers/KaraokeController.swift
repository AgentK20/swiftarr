import Vapor
import Fluent
import PostgresNIO

/// Methods for accessing the list of boardgames available in the onboard Games Library.
struct KaraokeController: APIRouteCollection {

	/// Required. Registers routes to the incoming router.
	func registerRoutes(_ app: Application) throws {

		// convenience route group for all /api/v3/karaoke endpoints
		let baseRoute = app.grouped("api", "v3", "karaoke")
	
		let flexAuthGroup = addFlexCacheAuthGroup(to: baseRoute)
		flexAuthGroup.get("", use: getKaraokeSongs)
		flexAuthGroup.get(songIDParam, use: getKaraokeSong)
		flexAuthGroup.get("latest", use: getLatestPerformedSongs)
		
		let tokenAuthGroup = addTokenCacheAuthGroup(to: baseRoute)
		tokenAuthGroup.post(songIDParam, "favorite", use: addFavorite)
		tokenAuthGroup.post(songIDParam, "favorite", "remove", use: removeFavorite)
		tokenAuthGroup.delete(songIDParam, "favorite", use: removeFavorite)
		tokenAuthGroup.get("userismanager", use: userCanLogKaraokeSongPerformances)
		tokenAuthGroup.post(songIDParam, "logperformance", use: logSongPerformance)
	}
	
	/// `GET /api/v3/karaoke`
	/// 
	/// Returns an array of karaoke songs in a structure designed to support pagination. Can be called while not logged in; 
	/// if logged in favorite information is returned. 
	/// 
	/// This call can't be used to browse the entire ~25000 song library. You must specify either a search string with >2 chars, or 
	/// specify favorites=true.
	/// 
	/// **URL Query Parameters**
	/// * `?search=STRING` - Only show songs whose artist or title contains the given string.
	/// * `?favorite=TRUE` - Only return songs that have been favorited by current user. 
	///	* `?start=INT` - Offset from start of results set
	/// * `?limit=INT` - the maximum number of songs to retrieve: 1-200, default is 50. 
	/// 
    /// - Returns: <doc:KaraokeSongResponseData>
	func getKaraokeSongs(_ req: Request) throws -> EventLoopFuture<KaraokeSongResponseData> {
		struct SongQueryOptions: Decodable {
			var search: String?
			var favorite: String?
			var start: Int?
			var limit: Int?
		}
 		let filters = try req.query.decode(SongQueryOptions.self)
        let start = filters.start ?? 0
        let limit = (filters.limit ?? 50).clamped(to: 0...Settings.shared.maximumTwarrts)
        var futureFavorites: EventLoopFuture<[KaraokeFavorite]> = req.eventLoop.future([])
		let songQuery = KaraokeSong.query(on: req.db).sort(\.$artist, .ascending).sort(\.$title, .ascending)
		if let search = filters.search {
			songQuery.group(.or) { group in 
				group.filter(\.$artist, .custom("ILIKE"), "%\(search)%").filter(\.$title, .custom("ILIKE"), "%\(search)%")
			}
		}
		var filteringFavorites = false
		if let user = req.auth.get(UserCacheData.self) {
			futureFavorites = KaraokeFavorite.query(on: req.db).filter(\.$user.$id == user.userID).all()
			if let fav = filters.favorite, fav.lowercased() == "true" {
				filteringFavorites = true
				songQuery.join(KaraokeFavorite.self, on: \KaraokeSong.$id == \KaraokeFavorite.$song.$id)
						.filter(KaraokeFavorite.self, \.$user.$id == user.userID)
			}
		}
		else {
			if let fav = filters.favorite, fav.lowercased() == "true" {
				throw Abort(.badRequest, reason: "Must be logged in to view favorites")
			}
		}
		let hasSearchString = filters.search?.count ?? 0 >= 3
		guard filteringFavorites || hasSearchString else {
			throw Abort(.badRequest, reason: "Search string must have at least 3 characters.")
		}
		return songQuery.count().and(futureFavorites).flatMap { (totalFoundSongs, songFavorites) in
			return songQuery.range(start..<(start + limit)).with(\.$sungBy).all().flatMapThrowing { songs in
				let favoriteSet = Set(songFavorites.map { $0.$song.id })
				let songData = try songs.map { return try KaraokeSongData(with: $0, isFavorite: favoriteSet.contains($0.requireID())) }
				return KaraokeSongResponseData(totalSongs: totalFoundSongs, start: start, limit: limit, songs: songData)
			}
		}
	}
	
	/// `GET /api/v3/karaoke/:song_id`
	/// 
	/// Returns a single karaoke song. Can be called while not logged in; if logged in favorite information is returned.
	/// 
    /// - Returns: <doc:KaraokeSongData>
	func getKaraokeSong(_ req: Request) throws -> EventLoopFuture<KaraokeSongData> {
		return KaraokeSong.findFromParameter(songIDParam, on: req).throwingFlatMap { song in
     		var favoriteFuture: EventLoopFuture<KaraokeFavorite?> = req.eventLoop.future(nil)
     		if let user = req.auth.get(UserCacheData.self) {
				favoriteFuture = song.$favorites.$pivots.query(on: req.db).filter(\.$user.$id == user.userID).first()
			}
			return favoriteFuture.flatMapThrowing { favorite in
				return try KaraokeSongData(with: song, isFavorite: favorite != nil)
			}
		}		
	}
	
	/// `GET /api/v3/karaoke/performance`
	/// 
	/// Returns an array of the 10 most recent karaoke songs that have been marked as being performed.
	/// Can be called while not logged in; if logged in favorite information is returned.
	/// 
	/// Intent of this call is to let people see what's been happening recently in the karaoke lounge without making a complete index of 
	/// `who sang what song when` available.
	/// 
    /// - Returns: An array of up to 10 <doc:KaraokePerformedSongsData>
	func getLatestPerformedSongs(_ req: Request) throws -> EventLoopFuture<[KaraokePerformedSongsData]> {
		return KaraokePlayedSong.query(on: req.db).sort(\.$createdAt, .descending).range(0..<10).with(\.$song).all().map { recentSongs in
			return recentSongs.map { 
				KaraokePerformedSongsData(artist: $0.song.artist, songName: $0.song.title,
						performers: $0.performers, time: $0.createdAt ?? Date())
			}
		}
	}

    /// `POST /api/v3/karaoke/:songID/favorite`
    ///
    /// Add the specified `Boardgame` to the user's favorite boardgame list. Must be logged in
    ///
    /// - Parameter boardgameID: in URL path
    /// - Returns: 201 Created on success.
    func addFavorite(_ req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let user = try req.auth.require(UserCacheData.self)
        return KaraokeSong.findFromParameter(songIDParam, on: req).throwingFlatMap { song in
        	let newFav = try KaraokeFavorite(user.userID, song)
        	return newFav.save(on: req.db).transform(to: .created).flatMapErrorThrowing { err in
				if let sqlError = err as? PostgresError, sqlError.code == .uniqueViolation {
					return .ok
				}
				throw err
			}
		}
    }
    
    /// `POST /api/v3/karaoke/:songID/favorite/remove`
    /// `DELETE /api/v3/karaoke/:songID/favorite`
    ///
    /// Remove the specified `Boardgame` from the user's boardgame favorite list.
    ///
    /// - Parameter boardgameID: in URL path
    /// - Returns: 204 No Content on success.
    func removeFavorite(_ req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let user = try req.auth.require(UserCacheData.self)
        guard let songID = req.parameters.get(songIDParam.paramString, as: UUID.self) else {
        	throw Abort(.badRequest, reason: "Could not make UUID out of song parameter")
        }
        return KaraokeFavorite.query(on: req.db).filter(\.$user.$id == user.userID)
        		.filter(\.$song.$id == songID).first().throwingFlatMap { pivot in
        	guard let pivot = pivot else {
        		return req.eventLoop.future(.ok)
        	}
        	return pivot.delete(on: req.db).transform(to: .noContent)
        }
    }
    
    /// `GET /api/v3/karaoke/userismanager`
    ///
    /// Returns TRUE in isAuthorized if the user is a Karaoke Manager, meaning they can create entries in  the Karaoke Song Log.
    ///
    /// - Returns: 200 OK
    func userCanLogKaraokeSongPerformances(_ req: Request) throws -> EventLoopFuture<UserAuthorizedToCreateKaraokeLogs> {
    	let user = try req.auth.require(UserCacheData.self)
    	return req.redis.sismember(user.userID, of: "KaraokeSongManagers").map { isMember in
    		return UserAuthorizedToCreateKaraokeLogs(isAuthorized: isMember)
		}
    }
    
    /// `POST /api/v3/karaoke/:songID/logperformance`
    ///
    /// Allows authorized users to created log entries for karaoke performances. Each log entry is timestamped, references a song in the Karaoke song
	/// catalog, and has a freeform text field for entering the song performer(s). Song performers don't need to be Twit-arr users and may not have accounts,
	/// but @mentions in the note field should be processed. 
    ///
    /// - Parameter songID: in URL path
    /// - Parameter note: <doc:NoteCreateData> in request body
    /// - Returns: 201 Created on success.
    func logSongPerformance(_ req: Request) throws -> EventLoopFuture<HTTPStatus> {
    	let user = try req.auth.require(UserCacheData.self)
    	return req.redis.sismember(user.userID, of: "KaraokeSongManagers")
    			.and(KaraokeSong.findFromParameter(songIDParam, on: req)).throwingFlatMap { (isMember, song) in
    		guard isMember else {
        		throw Abort(.forbidden, reason: "User is not authorized to log Karaoke song performances.")
    		}
			let data = try ValidatingJSONDecoder().decode(NoteCreateData.self, fromBodyOf: req)
    		let newSongLogEntry = try KaraokePlayedSong(singer: data.note, song: song, managerID: user.userID)
			return newSongLogEntry.save(on: req.db).transform(to: .created)
    	}
    }
    
// MARK: - Utilities

}
