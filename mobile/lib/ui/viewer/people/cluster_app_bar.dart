import 'dart:async';

import "package:flutter/foundation.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import "package:photos/db/files_db.dart";
import "package:photos/events/people_changed_event.dart";
import 'package:photos/events/subscription_purchased_event.dart';
import "package:photos/face/db.dart";
import "package:photos/face/model/person.dart";
import "package:photos/models/file/file.dart";
import 'package:photos/models/gallery_type.dart';
import 'package:photos/models/selected_files.dart';
import 'package:photos/services/collections_service.dart';
import "package:photos/services/machine_learning/face_ml/face_ml_result.dart";
import "package:photos/services/machine_learning/face_ml/feedback/cluster_feedback.dart";
import 'package:photos/ui/actions/collection/collection_sharing_actions.dart';
import "package:photos/ui/common/popup_item.dart";
import "package:photos/ui/viewer/people/cluster_breakup_page.dart";
import "package:photos/ui/viewer/people/cluster_page.dart";
import "package:photos/utils/dialog_util.dart";

class ClusterAppBar extends StatefulWidget {
  final GalleryType type;
  final String? title;
  final SelectedFiles selectedFiles;
  final int clusterID;
  final PersonEntity? person;

  const ClusterAppBar(
    this.type,
    this.title,
    this.selectedFiles,
    this.clusterID, {
    this.person,
    Key? key,
  }) : super(key: key);

  @override
  State<ClusterAppBar> createState() => _AppBarWidgetState();
}

enum ClusterPopupAction {
  setCover,
  breakupCluster,
  breakupClusterDebug,
  ignore,
}

class _AppBarWidgetState extends State<ClusterAppBar> {
  final _logger = Logger("_AppBarWidgetState");
  late StreamSubscription _userAuthEventSubscription;
  late Function() _selectedFilesListener;
  String? _appBarTitle;
  late CollectionActions collectionActions;
  final GlobalKey shareButtonKey = GlobalKey();
  bool isQuickLink = false;
  late GalleryType galleryType;

  @override
  void initState() {
    super.initState();
    _selectedFilesListener = () {
      setState(() {});
    };
    collectionActions = CollectionActions(CollectionsService.instance);
    widget.selectedFiles.addListener(_selectedFilesListener);
    _userAuthEventSubscription =
        Bus.instance.on<SubscriptionPurchasedEvent>().listen((event) {
      setState(() {});
    });
    _appBarTitle = widget.title;
    galleryType = widget.type;
  }

  @override
  void dispose() {
    _userAuthEventSubscription.cancel();
    widget.selectedFiles.removeListener(_selectedFilesListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppBar(
      elevation: 0,
      centerTitle: false,
      title: Text(
        _appBarTitle!,
        style:
            Theme.of(context).textTheme.headlineSmall!.copyWith(fontSize: 16),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      actions: _getDefaultActions(context),
    );
  }

  List<Widget> _getDefaultActions(BuildContext context) {
    final List<Widget> actions = <Widget>[];
    // If the user has selected files, don't show any actions
    if (widget.selectedFiles.files.isNotEmpty ||
        !Configuration.instance.hasConfiguredAccount()) {
      return actions;
    }

    final List<EntePopupMenuItem<ClusterPopupAction>> items = [];

    items.addAll(
      [
        EntePopupMenuItem(
          "Ignore person",
          value: ClusterPopupAction.ignore,
          icon: Icons.hide_image_outlined,
        ),
        EntePopupMenuItem(
          "Mixed grouping?",
          value: ClusterPopupAction.breakupCluster,
          icon: Icons.analytics_outlined,
        ),
      ],
    );
    if (kDebugMode) {
      items.add(
        EntePopupMenuItem(
          "Debug mixed grouping",
          value: ClusterPopupAction.breakupClusterDebug,
          icon: Icons.analytics_outlined,
        ),
      );
    }

    if (items.isNotEmpty) {
      actions.add(
        PopupMenuButton(
          itemBuilder: (context) {
            return items;
          },
          onSelected: (ClusterPopupAction value) async {
            if (value == ClusterPopupAction.breakupCluster) {
              // ignore: unawaited_futures
              await _breakUpCluster(context);
            } else if (value == ClusterPopupAction.ignore) {
              await _onIgnoredClusterClicked(context);
            } else if (value == ClusterPopupAction.breakupClusterDebug) {
              await _breakUpClusterDebug(context);
            }
            // else if (value == ClusterPopupAction.setCover) {
            //   await setCoverPhoto(context);
          },
        ),
      );
    }

    return actions;
  }

  Future<void> _onIgnoredClusterClicked(BuildContext context) async {
    await showChoiceDialog(
      context,
      title: "Are you sure you want to ignore this person?",
      body:
          "The person grouping will not be displayed in the discovery tap anymore. Photos will remain untouched.",
      firstButtonLabel: "Yes, confirm",
      firstButtonOnTap: () async {
        try {
          await ClusterFeedbackService.instance.ignoreCluster(widget.clusterID);
          Navigator.of(context).pop(); // Close the cluster page
        } catch (e, s) {
          _logger.severe('Ignoring a cluster failed', e, s);
          // await showGenericErrorDialog(context: context, error: e);
        }
      },
    );
  }

  Future<void> _breakUpCluster(BuildContext context) async {
    bool userConfirmed = false;
    List<EnteFile> biggestClusterFiles = [];
    int biggestClusterID = -1;
    await showChoiceDialog(
      context,
      title: "Does this grouping contain multiple people?",
      body:
          "We will automatically analyze the grouping to determine if there are multiple people present, and separate them out again. This may take a few seconds.",
      firstButtonLabel: "Yes, confirm",
      firstButtonOnTap: () async {
        try {
          final breakupResult = await ClusterFeedbackService.instance
              .breakUpCluster(widget.clusterID);
          final Map<int, List<String>> newClusterIDToFaceIDs =
              breakupResult.newClusterIdToFaceIds!;
          final Map<String, int> newFaceIdToClusterID =
              breakupResult.newFaceIdToCluster;

          // Update to delete the old clusters and save the new clusters
          await FaceMLDataDB.instance.deleteClusterSummary(widget.clusterID);
          await FaceMLDataDB.instance
              .clusterSummaryUpdate(breakupResult.newClusterSummaries!);
          await FaceMLDataDB.instance
              .updateFaceIdToClusterId(newFaceIdToClusterID);

          // Find the biggest cluster
          biggestClusterID = -1;
          int biggestClusterSize = 0;
          for (final MapEntry<int, List<String>> clusterToFaces
              in newClusterIDToFaceIDs.entries) {
            if (clusterToFaces.value.length > biggestClusterSize) {
              biggestClusterSize = clusterToFaces.value.length;
              biggestClusterID = clusterToFaces.key;
            }
          }
          // Get the files for the biggest new cluster
          final biggestClusterFileIDs = newClusterIDToFaceIDs[biggestClusterID]!
              .map((e) => getFileIdFromFaceId(e))
              .toList();
          biggestClusterFiles = await FilesDB.instance
              .getFilesFromIDs(
                biggestClusterFileIDs,
              )
              .then((mapping) => mapping.values.toList());
          // Sort the files to prevent issues with the order of the files in gallery
          biggestClusterFiles
              .sort((a, b) => b.creationTime!.compareTo(a.creationTime!));

          userConfirmed = true;
        } catch (e, s) {
          _logger.severe('Breakup cluster failed', e, s);
          // await showGenericErrorDialog(context: context, error: e);
        }
      },
    );
    if (userConfirmed) {
      // Close the old cluster page
      Navigator.of(context).pop();

      // Push the new cluster page
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ClusterPage(
            biggestClusterFiles,
            clusterID: biggestClusterID,
          ),
        ),
      );
      Bus.instance.fire(PeopleChangedEvent());
    }
  }

  Future<void> _breakUpClusterDebug(BuildContext context) async {
    final breakupResult =
        await ClusterFeedbackService.instance.breakUpCluster(widget.clusterID);

    final Map<int, List<String>> newClusterIDToFaceIDs =
        breakupResult.newClusterIdToFaceIds!;

    final allFileIDs = newClusterIDToFaceIDs.values
        .expand((e) => e)
        .map((e) => getFileIdFromFaceId(e))
        .toList();

    final fileIDtoFile = await FilesDB.instance.getFilesFromIDs(
      allFileIDs,
    );

    final newClusterIDToFiles = newClusterIDToFaceIDs.map(
      (key, value) => MapEntry(
        key,
        value
            .map((faceId) => fileIDtoFile[getFileIdFromFaceId(faceId)]!)
            .toList(),
      ),
    );

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ClusterBreakupPage(
          newClusterIDToFiles,
          "(Analysis)",
        ),
      ),
    );
  }
}
