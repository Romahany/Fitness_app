import 'package:fitness_app/config/base/base_response.dart';
import 'package:fitness_app/config/errors/app_failure.dart';
import 'package:fitness_app/features/chat/domain/repository/catalog_repository.dart';
import 'package:fitness_app/features/chat/domain/repository/chat_repository.dart';
import 'package:fitness_app/features/chat/domain/use_cases/send_message_use_case.dart';
import 'package:fitness_app/features/chat/presentation/manager/chat_cubit.dart';
import 'package:fitness_app/features/chat/presentation/manager/chat_event.dart';
import 'package:fitness_app/config/base/base_ui_event.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockSendMessageUseCase extends Mock implements SendMessageUseCase {}

class MockChatRepository extends Mock implements ChatRepository {}

class MockCatalogRepository extends Mock implements CatalogRepository {}

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late MockSendMessageUseCase sendMessageUseCase;
  late MockChatRepository chatRepository;
  late MockCatalogRepository catalogRepository;
  late MockFlutterSecureStorage storage;
  late ChatCubit cubit;

  setUpAll(() {
    registerFallbackValue((String _) {});
  });

  setUp(() {
    sendMessageUseCase = MockSendMessageUseCase();
    chatRepository = MockChatRepository();
    catalogRepository = MockCatalogRepository();
    storage = MockFlutterSecureStorage();
    cubit = ChatCubit(
      sendMessageUseCase,
      chatRepository,
      catalogRepository,
      storage,
    );

    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((_) async => 'user-id');
  });

  tearDown(() async {
    await cubit.close();
  });

    test('handles failure gracefully and emits ShowFailureMessage', () async {
      when(
        () => sendMessageUseCase(
          userId: any(named: 'userId'),
          chatId: any(named: 'chatId'),
          userText: any(named: 'userText'),
          onChatCreated: any(named: 'onChatCreated'),
        ),
      ).thenAnswer((_) async => const Error<ChatOutput>(UnknownFailure()));

      final eventFuture = cubit.uiEventStream.first;
      await cubit.onEvent(const SendMessageEvent('  Try again  '));

      expect(cubit.state.isSending, isFalse);
      expect(cubit.state.messagesState.data?.length, 1);
      expect(cubit.state.messagesState.data?.first.text, 'Try again');
      expect(await eventFuture, isA<ShowFailureMessage>());
    });

    test('adds response and updates activeChatId on success', () async {
      when(
        () => sendMessageUseCase(
          userId: any(named: 'userId'),
          chatId: any(named: 'chatId'),
          userText: any(named: 'userText'),
          onChatCreated: any(named: 'onChatCreated'),
        ),
      ).thenAnswer(
        (_) async => const Success<ChatOutput>(
          ChatOutput(
            chatId: 'chat-123',
            answerText: 'Hello there!',
            exercises: [],
            meals: [],
            totalTokensUsed: 100,
            isNearTokenLimit: false,
          ),
        ),
      );

      await cubit.onEvent(const SendMessageEvent('Hello'));

      expect(cubit.state.isSending, isFalse);
      expect(cubit.state.activeChatId, 'chat-123');
      expect(cubit.state.messagesState.data?.length, 2);
      expect(cubit.state.messagesState.data?.first.text, 'Hello');
      expect(cubit.state.messagesState.data?.last.text, 'Hello there!');
      expect(cubit.state.messagesState.data?.last.isUser, isFalse);
    });
}
