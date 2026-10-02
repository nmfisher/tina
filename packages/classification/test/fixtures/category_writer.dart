import 'package:classification/category_store.dart';
import 'package:classification/utterance.dart';

Future<void> main(List<String> args) async {
  final store = FileInputCategoryStore(args[0]);
  final learned = await store.learn(
    'intent',
    InputCategory(
      id: 'greeting',
      label: 'greeting',
      description: 'A conversational greeting.',
      question: 'Is the latest input a greeting?',
    ),
  );
  for (var i = 0; i < int.parse(args[1]); i++) {
    await store.record('intent', ['projectQuestion', learned!.id, 'other']);
  }
}
