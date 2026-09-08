/// Session selection independent of CLI parsing and terminal setup.
class ResumeRequest {
  final String? resumeSessionId;
  final bool continueLatest;
  const ResumeRequest({this.resumeSessionId, this.continueLatest = false});
}
