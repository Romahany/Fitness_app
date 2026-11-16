import 'package:fitness_app/config/base/base_response.dart';
import 'package:fitness_app/config/errors/app_failure.dart';
import 'package:fitness_app/features/chat/domain/entities/catalog_filter_metadata.dart';
import 'package:fitness_app/features/chat/domain/entities/message_entity.dart';
import 'package:fitness_app/features/chat/domain/repository/catalog_repository.dart';
import 'package:fitness_app/features/chat/domain/repository/chat_repository.dart';
import 'package:fitness_app/features/chat/domain/use_cases/send_message_use_case.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockCatalogRepository extends Mock implements CatalogRepository {}

class MockChatRepository extends Mock implements ChatRepository {}

class FakeMessageEntity extends Fake implements MessageEntity {}

void main() {
  late MockCatalogRepository catalogRepository;
  late MockChatRepository chatRepository;
  late SendMessageUseCase useCase;

  setUpAll(() {
    registerFallbackValue(FakeMessageEntity());
  });

  setUp(() {
    catalogRepository = MockCatalogRepository();
    chatRepository = MockChatRepository();
    useCase = SendMessageUseCase(catalogRepository, chatRepository);

    when(() => catalogRepository.getFilterMetadata()).thenAnswer(
      (_) async => const CatalogFilterMetadata(
        muscleGroups: [],
        difficulties: [],
        equipments: [],
        mealCategories: [],
        mealAreas: [],
      ),
    );
    when(
      () => chatRepository.getChatHistory(chatId: 'chat-id', limit: 20),
    ).thenAnswer((_) async => const Error(UnknownFailure()));
  });

  test(
    'returns history failure without saving or sending the new message',
    () async {
      final result = await useCase(
        userId: 'user-id',
        chatId: 'chat-id',
        userText: 'My message',
      );

      expect(result, isA<Error<ChatOutput>>());
      expect((result as Error<ChatOutput>).failure, isA<UnknownFailure>());
      verifyNever(
        () => chatRepository.saveMessage(message: any(named: 'message')),
      );
    },
  );
}
