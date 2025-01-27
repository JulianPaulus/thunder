import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:lemmy_api_client/v3.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:stream_transform/stream_transform.dart';

import 'package:thunder/account/models/account.dart';
import 'package:thunder/core/auth/helpers/fetch_account.dart';
import 'package:thunder/core/models/post_view_media.dart';
import 'package:thunder/core/singletons/lemmy_client.dart';
import 'package:thunder/core/singletons/preferences.dart';
import 'package:thunder/utils/constants.dart';
import 'package:thunder/utils/post.dart';

part 'community_event.dart';
part 'community_state.dart';

const throttleDuration = Duration(milliseconds: 300);
const timeout = Duration(seconds: 5);

EventTransformer<E> throttleDroppable<E>(Duration duration) {
  return (events, mapper) => droppable<E>().call(events.throttle(duration), mapper);
}

class CommunityBloc extends Bloc<CommunityEvent, CommunityState> {
  CommunityBloc() : super(const CommunityState()) {
    on<GetCommunityPostsEvent>(
      _getCommunityPostsEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<MarkPostAsReadEvent>(
      _markPostAsReadEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<VotePostEvent>(
      _votePostEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<SavePostEvent>(
      _savePostEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<ForceRefreshEvent>(
      _forceRefreshEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<ChangeCommunitySubsciptionStatusEvent>(
      _changeCommunitySubsciptionStatusEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<CreatePostEvent>(
      _createPostEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<UpdatePostEvent>(
      _updatePostEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<BlockCommunityEvent>(
      _blockCommunityEvent,
      transformer: throttleDroppable(throttleDuration),
    );
  }

  Future<void> _updatePostEvent(UpdatePostEvent event, Emitter<CommunityState> emit) async {
    emit(state.copyWith(status: CommunityStatus.refreshing, communityId: state.communityId, listingType: state.listingType));

    List<PostViewMedia> updatedPostViews = state.postViews!.map((communityPostView) {
      if (communityPostView.postView.post.id == event.postViewMedia.postView.post.id) {
        return event.postViewMedia;
      } else {
        return communityPostView;
      }
    }).toList();

    emit(state.copyWith(status: CommunityStatus.success, communityId: state.communityId, listingType: state.listingType, postViews: updatedPostViews));
  }

  Future<void> _forceRefreshEvent(ForceRefreshEvent event, Emitter<CommunityState> emit) async {
    emit(state.copyWith(status: CommunityStatus.refreshing, communityId: state.communityId, listingType: state.listingType));
    emit(state.copyWith(status: CommunityStatus.success, communityId: state.communityId, listingType: state.listingType));
  }

  Future<void> _markPostAsReadEvent(MarkPostAsReadEvent event, Emitter<CommunityState> emit) async {
    try {
      emit(state.copyWith(status: CommunityStatus.refreshing, communityId: state.communityId, listingType: state.listingType));

      PostView postView = await markPostAsRead(event.postId, event.read);

      // Find the specific post to update
      int existingPostViewIndex = state.postViews!.indexWhere((postViewMedia) => postViewMedia.postView.post.id == event.postId);
      state.postViews![existingPostViewIndex].postView = postView;

      return emit(state.copyWith(status: CommunityStatus.success, communityId: state.communityId, listingType: state.listingType));
    } catch (e, s) {
      return emit(state.copyWith(
        status: CommunityStatus.failure,
        errorMessage: e.toString(),
        communityId: state.communityId,
        listingType: state.listingType,
        communityName: state.communityName,
      ));
    }
  }

  Future<void> _votePostEvent(VotePostEvent event, Emitter<CommunityState> emit) async {
    try {
      emit(state.copyWith(status: CommunityStatus.refreshing, communityId: state.communityId, listingType: state.listingType));

      // Optimistically update the post
      int existingPostViewIndex = state.postViews!.indexWhere((postViewMedia) => postViewMedia.postView.post.id == event.postId);
      PostViewMedia postViewMedia = state.postViews![existingPostViewIndex];

      PostView originalPostView = state.postViews![existingPostViewIndex].postView;

      PostView updatedPostView = optimisticallyVotePost(postViewMedia, event.score);
      state.postViews![existingPostViewIndex].postView = updatedPostView;

      // Immediately set the status, and continue
      emit(state.copyWith(status: CommunityStatus.success, communityId: state.communityId, listingType: state.listingType));
      emit(state.copyWith(status: CommunityStatus.refreshing, communityId: state.communityId, listingType: state.listingType));

      PostView postView = await votePost(event.postId, event.score).timeout(timeout, onTimeout: () {
        state.postViews![existingPostViewIndex].postView = originalPostView;
        throw Exception('Error: Timeout when attempting to vote post');
      });

      // Find the specific post to update
      state.postViews![existingPostViewIndex].postView = postView;

      return emit(state.copyWith(status: CommunityStatus.success, communityId: state.communityId, listingType: state.listingType));
    } catch (e, s) {
      return emit(state.copyWith(
        status: CommunityStatus.failure,
        errorMessage: e.toString(),
        communityId: state.communityId,
        listingType: state.listingType,
        communityName: state.communityName,
      ));
    }
  }

  Future<void> _savePostEvent(SavePostEvent event, Emitter<CommunityState> emit) async {
    try {
      emit(state.copyWith(status: CommunityStatus.refreshing, communityId: state.communityId, listingType: state.listingType, communityName: state.communityName));

      PostView postView = await savePost(event.postId, event.save);

      // Find the specific post to update
      int existingPostViewIndex = state.postViews!.indexWhere((postViewMedia) => postViewMedia.postView.post.id == event.postId);
      state.postViews![existingPostViewIndex].postView = postView;

      return emit(state.copyWith(status: CommunityStatus.success, communityId: state.communityId, listingType: state.listingType, communityName: state.communityName));
    } catch (e, s) {
      return emit(state.copyWith(
        status: CommunityStatus.failure,
        errorMessage: e.toString(),
        communityId: state.communityId,
        listingType: state.listingType,
        communityName: state.communityName,
      ));
    }
  }

  Future<void> _getCommunityPostsEvent(GetCommunityPostsEvent event, Emitter<CommunityState> emit) async {
    int limit = 10;

    SharedPreferences prefs = (await UserPreferences.instance).sharedPreferences;

    PostListingType defaultListingType;
    SortType defaultSortType;
    bool tabletMode;

    try {
      defaultListingType = PostListingType.values.byName(prefs.getString("setting_general_default_listing_type") ?? DEFAULT_LISTING_TYPE.name);
      defaultSortType = SortType.values.byName(prefs.getString("setting_general_default_sort_type") ?? DEFAULT_SORT_TYPE.name);
      tabletMode = prefs.getBool('setting_post_tablet_mode') ?? false;
    } catch (e) {
      defaultListingType = PostListingType.values.byName(DEFAULT_LISTING_TYPE.name);
      defaultSortType = SortType.values.byName(DEFAULT_SORT_TYPE.name);
      tabletMode = false;
    }

    try {
      Account? account = await fetchActiveProfileAccount();

      LemmyApiV3 lemmy = LemmyClient.instance.lemmyApiV3;

      if (event.reset) {
        emit(state.copyWith(status: CommunityStatus.loading));

        int? communityId = event.communityId;
        String? communityName = event.communityName;
        PostListingType? listingType = (communityId != null || communityName != null) ? null : (event.listingType ?? defaultListingType);
        SortType sortType = event.sortType ?? (state.sortType ?? defaultSortType);

        // Fetch community's information
        SubscribedType? subscribedType;
        FullCommunityView? getCommunityResponse;

        if (communityId != null || communityName != null) {
          getCommunityResponse = await lemmy.run(GetCommunity(
            auth: account?.jwt,
            id: communityId,
            name: event.communityName,
          ));

          subscribedType = getCommunityResponse?.communityView.subscribed;
        }

        // Fetch community's posts
        List<PostViewMedia> posts = [];
        Set<int> postIds = {};
        int currentPage = 1;

        do {
          List<PostView> batch = await lemmy.run(GetPosts(
            auth: account?.jwt,
            page: currentPage,
            limit: limit,
            sort: sortType,
            type: listingType,
            communityId: communityId ?? getCommunityResponse?.communityView.community.id,
            communityName: event.communityName,
          ));

          currentPage++;

          // Parse the posts and add in media information which is used elsewhere in the app
          List<PostViewMedia> formattedPosts = await parsePostViews(batch);
          posts.addAll(formattedPosts);

          for (PostViewMedia post in formattedPosts) {
            postIds.add(post.postView.post.id);
          }

          emit(
            state.copyWith(
              status: CommunityStatus.success,
              page: tabletMode ? currentPage + 1 : currentPage,
              postViews: posts,
              postIds: postIds,
              listingType: listingType,
              communityId: communityId,
              communityName: event.communityName,
              hasReachedEnd: posts.isEmpty || posts.length < limit,
              subscribedType: subscribedType,
              sortType: sortType,
              communityInfo: getCommunityResponse,
            ),
          );
        } while (tabletMode && posts.length < limit && currentPage <= 2); // Fetch two batches

        return;
      } else {
        if (state.hasReachedEnd) {
          // Stop extra requests if we've reached the end
          emit(state.copyWith(status: CommunityStatus.success, listingType: state.listingType, communityId: state.communityId, communityName: state.communityName));
          return;
        }

        emit(state.copyWith(status: CommunityStatus.refreshing, listingType: state.listingType, communityId: state.communityId, communityName: state.communityName));

        int? communityId = event.communityId ?? state.communityId;
        PostListingType? listingType = (communityId != null) ? null : (event.listingType ?? state.listingType);
        SortType sortType = event.sortType ?? (state.sortType ?? defaultSortType);

        // Fetch more posts from the community
        List<PostViewMedia> posts = List.from(state.postViews ?? []);
        int currentPage = state.page;

        do {
          List<PostView> batch = await lemmy.run(GetPosts(
            auth: account?.jwt,
            page: currentPage,
            limit: limit,
            sort: sortType,
            type: state.listingType,
            communityId: state.communityId,
            communityName: state.communityName,
          ));

          currentPage++;

          // Parse the posts, and append them to the existing list
          List<PostViewMedia> postMedias = await parsePostViews(batch);
          posts.addAll(postMedias);

          List<PostViewMedia> postViews = List.from(state.postViews ?? []);
          Set<int> postIds = Set.from(state.postIds ?? {});

          // Ensure we don't add existing posts to view
          for (PostViewMedia postMedia in postMedias) {
            int id = postMedia.postView.post.id;
            if (!postIds.contains(id)) {
              postIds.add(id);
              postViews.add(postMedia);
            }
          }

          emit(
            state.copyWith(
              status: CommunityStatus.success,
              page: tabletMode ? currentPage + 1 : currentPage,
              postViews: posts,
              postIds: postIds,
              communityId: communityId,
              communityName: state.communityName,
              listingType: listingType,
              hasReachedEnd: posts.isEmpty,
              subscribedType: state.subscribedType,
              sortType: sortType,
            ),
          );
        } while (tabletMode && posts.length < limit && currentPage <= state.page + 2); // Fetch two batches

        return;
      }
    } catch (e, s) {
      emit(state.copyWith(status: CommunityStatus.failure, errorMessage: e.toString(), listingType: state.listingType, communityId: state.communityId, communityName: state.communityName));
    }
  }

  Future<void> _changeCommunitySubsciptionStatusEvent(ChangeCommunitySubsciptionStatusEvent event, Emitter<CommunityState> emit) async {
    try {
      emit(state.copyWith(status: CommunityStatus.refreshing, communityId: state.communityId, listingType: state.listingType, communityName: state.communityName));

      Account? account = await fetchActiveProfileAccount();
      LemmyApiV3 lemmy = LemmyClient.instance.lemmyApiV3;

      if (account?.jwt == null) return;

      CommunityView communityView = await lemmy.run(FollowCommunity(
        auth: account!.jwt!,
        communityId: event.communityId,
        follow: event.follow,
      ));

      emit(state.copyWith(
        status: CommunityStatus.success,
        communityId: state.communityId,
        listingType: state.listingType,
        communityName: state.communityName,
        subscribedType: communityView.subscribed,
      ));

      await Future.delayed(const Duration(seconds: 1));

      // Update the community details again in case the subscribed type changed
      final fullCommunityView = await lemmy.run(GetCommunity(
        auth: account.jwt,
        id: event.communityId,
        name: state.communityName,
      ));

      return emit(state.copyWith(
        status: CommunityStatus.success,
        communityId: state.communityId,
        listingType: state.listingType,
        communityName: state.communityName,
        subscribedType: fullCommunityView.communityView.subscribed,
      ));
    } catch (e, s) {
      return emit(
        state.copyWith(
          status: CommunityStatus.failure,
          errorMessage: e.toString(),
          communityId: state.communityId,
          listingType: state.listingType,
        ),
      );
    }
  }

  Future<void> _createPostEvent(CreatePostEvent event, Emitter<CommunityState> emit) async {
    try {
      emit(state.copyWith(status: CommunityStatus.refreshing, communityId: state.communityId, listingType: state.listingType, communityName: state.communityName));

      Account? account = await fetchActiveProfileAccount();
      LemmyApiV3 lemmy = LemmyClient.instance.lemmyApiV3;

      if (account?.jwt == null) {
        return emit(
          state.copyWith(
            status: CommunityStatus.failure,
            errorMessage: 'You are not logged in. Cannot create a post.',
            communityId: state.communityId,
            listingType: state.listingType,
          ),
        );
      }

      if (state.communityId == null) {
        return emit(
          state.copyWith(
            status: CommunityStatus.failure,
            errorMessage: 'Could not determine community to post to.',
            communityId: state.communityId,
            listingType: state.listingType,
          ),
        );
      }

      PostView postView = await lemmy.run(CreatePost(auth: account!.jwt!, communityId: state.communityId!, name: event.name, body: event.body, url: event.url, nsfw: event.nsfw));

      // Parse the posts, and append them to the existing list
      List<PostViewMedia> posts = await parsePostViews([postView]);
      List<PostViewMedia> postViews = List.from(state.postViews ?? []);
      postViews.addAll(posts);

      return emit(state.copyWith(
        status: CommunityStatus.success,
        postViews: postViews,
        communityId: state.communityId,
        listingType: state.listingType,
        communityName: state.communityName,
      ));
    } catch (e, s) {
      return emit(
        state.copyWith(
          status: CommunityStatus.failure,
          errorMessage: e.toString(),
          communityId: state.communityId,
          listingType: state.listingType,
        ),
      );
    }
  }

  Future<void> _blockCommunityEvent(BlockCommunityEvent event, Emitter<CommunityState> emit) async {
    try {
      emit(state.copyWith(status: CommunityStatus.refreshing, communityId: state.communityId, listingType: state.listingType, communityName: state.communityName));

      Account? account = await fetchActiveProfileAccount();
      LemmyApiV3 lemmy = LemmyClient.instance.lemmyApiV3;

      if (account?.jwt == null) {
        return emit(
          state.copyWith(
            status: CommunityStatus.failure,
            errorMessage: 'You are not logged in. Cannot block community.',
            communityId: state.communityId,
            listingType: state.listingType,
          ),
        );
      }

      BlockedCommunity blockedCommunity = await lemmy.run(BlockCommunity(
        auth: account!.jwt!,
        communityId: event.communityId,
        block: event.block,
      ));

      return emit(state.copyWith(
        status: CommunityStatus.success,
        communityId: state.communityId,
        listingType: state.listingType,
        communityName: state.communityName,
        blockedCommunity: blockedCommunity,
      ));
    } catch (e, s) {
      return emit(
        state.copyWith(
          status: CommunityStatus.failure,
          errorMessage: e.toString(),
          communityId: state.communityId,
          listingType: state.listingType,
        ),
      );
    }
  }
}
